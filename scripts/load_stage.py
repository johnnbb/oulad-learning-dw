"""Execute Staging (STG) SQL to clean and standardize ODS data."""

from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL_FILE = ROOT / "sql" / "create_staging.sql"


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


def main() -> None:
    dsn = resolve_dsn()
    try:
        import psycopg
    except ImportError as error:
        raise SystemExit("Install requirements.txt before running staging") from error

    if not SQL_FILE.is_file():
        raise FileNotFoundError(f"Missing staging SQL file: {SQL_FILE}")

    print("🚀 开始执行 Staging 数据清洗与标准化...")
    with psycopg.connect(dsn) as connection:
        # 执行完整的 create_staging.sql 脚本
        sql_content = SQL_FILE.read_text(encoding="utf-8")
        connection.execute(sql_content)
        connection.commit()

        # 检查 stg schema 下现有的表及其实际行数
        with connection.cursor() as cursor:
            cursor.execute("""
                SELECT table_name 
                FROM information_schema.tables 
                WHERE table_schema = 'stg' 
                ORDER BY table_name;
            """)
            tables = [row[0] for row in cursor.fetchall()]

            print("\n✅ Staging 层清洗构建成功！当前表清单与行数：")
            for t in tables:
                cursor.execute(f"SELECT COUNT(*) FROM stg.{t};")
                count = cursor.fetchone()[0]
                print(f"   - stg.{t:25s} : {count:>10,} 行")


if __name__ == "__main__":
    main()
