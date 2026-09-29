"""Copy one unchanged OULAD CSV into its PostgreSQL ODS landing table."""

from __future__ import annotations

import argparse
import csv
import os
from pathlib import Path


# ==========================================
# 1. 基础路径配置
# ==========================================
ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw" / "archive"  # 原始 7 份 CSV 数据所在目录
SQL_FILE = ROOT / "sql" / "create_ods.sql"  # ODS 层建表 DDL 语句文件

# ==========================================
# 2. 映射配置与字段白名单 (Security & Contract)
# ==========================================
# 作用：
# 1) 参数与文件映射：将命令行参数映射为具体的 CSV 文件名和 ODS 目标表名。
# 2) 防范 SQL 注入：数据库标识符（表名、列名）不直接从外部输入或 CSV 中动态提取，全部采用白名单硬编码。
# 3) 契约校验白名单：用于核对 CSV 文件实际表头与预期是否严格一致，避免数据错位。
# 结构: 参数名 -> (CSV文件名, ODS目标表名, (字段名元组...))
TABLES = {
    "courses": ("courses.csv", "courses", ("code_module", "code_presentation", "module_presentation_length")),
    "assessments": ("assessments.csv", "assessments", ("code_module", "code_presentation", "id_assessment", "assessment_type", "date", "weight")),
    "vle": ("vle.csv", "vle", ("id_site", "code_module", "code_presentation", "activity_type", "week_from", "week_to")),
    "studentInfo": ("studentInfo.csv", "student_info", ("code_module", "code_presentation", "id_student", "gender", "region", "highest_education", "imd_band", "age_band", "num_of_prev_attempts", "studied_credits", "disability", "final_result")),
    "studentRegistration": ("studentRegistration.csv", "student_registration", ("code_module", "code_presentation", "id_student", "date_registration", "date_unregistration")),
    "studentAssessment": ("studentAssessment.csv", "student_assessment", ("id_assessment", "id_student", "date_submitted", "is_banked", "score")),
    "studentVle": ("studentVle.csv", "student_vle", ("code_module", "code_presentation", "id_student", "id_site", "date", "sum_click")),
}


# ==========================================
# 3. CSV 契约完整性校验函数
# ==========================================
def verify_file(path: Path, columns: tuple[str, ...]) -> None:
    """检查 CSV 是否存在，并校验其首行表头是否与设定的字段白名单完全匹配。"""
    if not path.is_file():
        raise FileNotFoundError(path)
    with path.open(newline="", encoding="utf-8-sig") as source:
        header = next(csv.reader(source), None)
    if header != list(columns):
        raise ValueError(f"Unexpected header in {path.name}: {header!r}")


def resolve_dsn() -> str:
    """获取数据库连接串，按优先级自动获取：系统环境变量 -> .env 文件 -> .env.example 文件"""
    if dsn := os.environ.get("OULAD_PG_DSN"):
        return dsn

    for filename in (".env", ".env.example"):
        env_file = ROOT / filename
        if env_file.is_file():
            for line in env_file.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line.startswith("OULAD_PG_DSN="):
                    val = line.split("=", 1)[1].strip().strip("'\"")
                    if val and not val.startswith("postgresql://USER:PASSWORD"):
                        return val

    raise SystemExit("未检测到数据库连接配置，请在系统环境变量或 .env 中设置 OULAD_PG_DSN")


# ==========================================
# 4. 主加载业务流程
# ==========================================
def main() -> None:
    # --- 步骤 4.1：解析命令行参数 ---
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--table", choices=TABLES, required=True, help="source table to load")
    args = parser.parse_args()
    file_name, table_name, columns = TABLES[args.table]
    path = RAW_DIR / file_name

    # --- 步骤 4.2：校验本地 CSV 文件与字段契约 ---
    verify_file(path, columns)

    # --- 步骤 4.3：自动获取数据库连接配置并检查数据库驱动 ---
    dsn = resolve_dsn()
    try:
        import psycopg
    except ImportError as error:
        raise SystemExit("Install requirements.txt before loading data") from error

    # --- 步骤 4.4：连接数据库并执行加载逻辑 ---
    with psycopg.connect(dsn) as connection:
        # 1. 幂等建表：自动执行 create_ods.sql，确保 ods schema 及各空表存在
        connection.execute(SQL_FILE.read_text(encoding="utf-8"))
        connection.commit()

        with connection.cursor() as cursor:
            # 2. 防重保护：如果目标表中已有任何记录，直接中断，拒绝重复加载
            cursor.execute(f"SELECT EXISTS (SELECT 1 FROM ods.{table_name} LIMIT 1)")
            if cursor.fetchone()[0]:
                raise RuntimeError(f"ods.{table_name} already contains data; refusing a duplicate load")

            # 3. 极速批量加载：使用 PostgreSQL 原生 COPY FROM STDIN 协议
            # 每次读取 1MB 流式传输，内存开销极小，适合千万元级大表（如 studentVle）
            column_sql = ", ".join(columns)
            with cursor.copy(f"COPY ods.{table_name} ({column_sql}) FROM STDIN WITH (FORMAT CSV, HEADER TRUE)") as target:
                with path.open("rb") as source:
                    while chunk := source.read(1024 * 1024):
                        target.write(chunk)
        print(f"Loaded {file_name} into ods.{table_name}")


if __name__ == "__main__":
    main()

