import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
SQL_FILE = ROOT / "sql" / "create_dim.sql"


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


def check_existing_dwd_data(cursor) -> dict[str, int]:
    """检测 DWD 层是否已存在事实表数据，防止 DIM 重跑引发下游代理键错位。"""
    cursor.execute("""
        SELECT table_name 
        FROM information_schema.tables 
        WHERE table_schema = 'dwd';
    """)
    dwd_tables = [row[0] for row in cursor.fetchall()]
    dwd_rows_found = {}
    for t in dwd_tables:
        cursor.execute(f"SELECT COUNT(*) FROM dwd.{t};")
        cnt = cursor.fetchone()[0]
        if cnt > 0:
            dwd_rows_found[t] = cnt
    return dwd_rows_found


def main() -> None:
    parser = argparse.ArgumentParser(description="装载数仓 DIM 维度层")
    parser.add_argument(
        "--cascade-dwd",
        action="store_true",
        help="在同一事务中连带重建并校验下游 DWD 事实表，防止代理键错位漂移（推荐模式）",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="忽略下游 DWD 存在的数据，强制单独重建 DIM 层（明确接受代理键错位风险）",
    )
    args = parser.parse_args()

    dsn = resolve_dsn()
    try:
        import psycopg
    except ImportError as error:
        raise SystemExit("Install requirements.txt before running dim load") from error

    if not SQL_FILE.is_file():
        raise FileNotFoundError(f"Missing DIM SQL file: {SQL_FILE}")

    with psycopg.connect(dsn) as connection:
        with connection.cursor() as cursor:
            # 1. 架构级安全检查：防止孤立重建 DIM 导致 DWD 代理键指向错误记录
            existing_dwd = check_existing_dwd_data(cursor)
            if existing_dwd and not args.cascade_dwd and not args.force:
                print("\n⚠️  【架构安全门禁拦截】检测到下游 DWD 层已存在事实表数据：")
                for t, cnt in existing_dwd.items():
                    print(f"   - dwd.{t}: {cnt:,} 行")
                print("\n🛑 原因分析：")
                print("   在当前基于整型代理键与逻辑外键的批处理数仓规范下，单独重建 DIM 会重新生成代理键序列，")
                print("   导致已有 DWD 事实表中的历史代理外键错位指向错误维度实体！")
                print("\n💡 正确操作指引：")
                print("   1. 协同重建 DIM 与 DWD（强烈推荐，在同一事务内原子执行）：")
                print("      python3 scripts/load_dim.py --cascade-dwd")
                print("   2. 确认仅需单独重跑 DIM 且接受代理键漂移风险（强制单跑）：")
                print("      python3 scripts/load_dim.py --force\n")
                raise SystemExit(1)

            try:
                print("🚀 开始执行 DIM 维度表构建与装载...")
                sql_content = SQL_FILE.read_text(encoding="utf-8")
                cursor.execute(sql_content)

                # 检查 dim schema 下现有的表及其实际行数
                cursor.execute("""
                    SELECT table_name 
                    FROM information_schema.tables 
                    WHERE table_schema = 'dim' 
                    ORDER BY table_name;
                """)
                tables = [row[0] for row in cursor.fetchall()]

                print("\n✅ DIM 层维度表构建成功！当前表清单与行数：")
                for t in tables:
                    cursor.execute(f"SELECT COUNT(*) FROM dim.{t};")
                    count = cursor.fetchone()[0]
                    print(f"   - dim.{t:25s} : {count:>10,} 行")

                # 若指定了 --cascade-dwd，则在同一事务中连带重建并校验 DWD
                if args.cascade_dwd:
                    print("\n🔗 正在同一事务中协同构建并校验 DWD 事实表...")
                    from scripts.load_dwd import build_and_validate_dwd
                    build_and_validate_dwd(cursor)

                # 只有全部执行与校验成功，才统一提交事务
                connection.commit()
                if args.cascade_dwd:
                    print("\n💾 DIM 与 DWD 协同重建及全量校验在同一事务内原子提交 (COMMIT) 成功！")
                else:
                    print("\n💾 DIM 层事务已安全提交 (COMMIT)！")
                    if existing_dwd and args.force:
                        print("⚠️  警告：由于强制单独重建了 DIM，请尽快重跑 DWD 以重新对齐代理键！")

            except Exception as err:
                connection.rollback()
                print(f"\n🛑 检测到异常已执行回滚 (ROLLBACK): {err}")
                raise


if __name__ == "__main__":
    main()
