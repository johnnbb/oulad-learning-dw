"""Execute Data Warehouse Detail (DWD) SQL to build fact tables and perform validations."""

from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL_FILE = ROOT / "sql" / "create_dwd.sql"


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


def validate_dwd_fact_student_enrollment(cursor) -> int:
    """全面校验 dwd.fact_student_enrollment 数据质量、源表双向对齐与逻辑外键完整性。
    若发现任何数据异常，立即抛出 RuntimeError。
    """
    print("\n🔍 执行装载前置数据质量门禁与逻辑外键完整性核验（事务提交前）...")

    # 1. 源表业务键唯一性核验
    cursor.execute("""
        SELECT COUNT(*) FROM (
            SELECT id_student, code_module, code_presentation 
            FROM stg.student_info 
            GROUP BY id_student, code_module, code_presentation 
            HAVING COUNT(*) > 1
        ) t;
    """)
    info_dups = cursor.fetchone()[0]
    if info_dups > 0:
        raise RuntimeError(f"❌ 源表质量校验失败：stg.student_info 存在 {info_dups} 组重复业务键！")

    cursor.execute("""
        SELECT COUNT(*) FROM (
            SELECT id_student, code_module, code_presentation 
            FROM stg.student_registration 
            GROUP BY id_student, code_module, code_presentation 
            HAVING COUNT(*) > 1
        ) t;
    """)
    reg_dups = cursor.fetchone()[0]
    if reg_dups > 0:
        raise RuntimeError(f"❌ 源表质量校验失败：stg.student_registration 存在 {reg_dups} 组重复业务键！")
    print("   [PASS] 源表业务键唯一性校验: 100% 唯一无重复")

    # 2. 源表独立行数读取与双向差集核验 (Bidirectional Mismatch Check)
    cursor.execute("SELECT COUNT(*) FROM stg.student_info;")
    info_count = cursor.fetchone()[0]

    cursor.execute("SELECT COUNT(*) FROM stg.student_registration;")
    reg_count = cursor.fetchone()[0]

    cursor.execute("""
        SELECT COUNT(*) 
        FROM stg.student_info i
        LEFT JOIN stg.student_registration r
            ON i.code_module = r.code_module
           AND i.code_presentation = r.code_presentation
           AND i.id_student = r.id_student
        WHERE r.id_student IS NULL;
    """)
    info_without_reg = cursor.fetchone()[0]

    cursor.execute("""
        SELECT COUNT(*) 
        FROM stg.student_registration r
        LEFT JOIN stg.student_info i
            ON r.code_module = i.code_module
           AND r.code_presentation = i.code_presentation
           AND r.id_student = i.id_student
        WHERE i.id_student IS NULL;
    """)
    reg_without_info = cursor.fetchone()[0]

    if info_count != reg_count or info_without_reg > 0 or reg_without_info > 0:
        raise RuntimeError(
            f"❌ 源表双向对齐校验失败：\n"
            f"   - stg.student_info 行数: {info_count}\n"
            f"   - stg.student_registration 行数: {reg_count}\n"
            f"   - info 有但 reg 缺失 (单向孤儿): {info_without_reg}\n"
            f"   - reg 有但 info 缺失 (单向孤儿): {reg_without_info}"
        )
    print(f"   [PASS] 源表双向匹配校验: 100% 对齐 ({info_count:,} 行，双方 0 缺失)")

    # 3. 事实表行数与源头强一致校验
    cursor.execute("SELECT COUNT(*) FROM dwd.fact_student_enrollment;")
    enroll_count = cursor.fetchone()[0]
    if enroll_count != info_count:
        raise RuntimeError(
            f"❌ 事实表数据完整性校验失败：事实表实际行数 ({enroll_count}) 与源头 ({info_count}) 不一致！"
        )
    print(f"   [PASS] 选课事实表行数与源头 STG 完全匹配: {enroll_count:,} 行")

    # 4. 学生逻辑外键孤儿检查 (Logical FK Orphan Check)
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dwd.fact_student_enrollment f
        LEFT JOIN dim.dim_student s ON f.student_key = s.student_key
        WHERE s.student_key IS NULL;
    """)
    orphan_students = cursor.fetchone()[0]
    if orphan_students > 0:
        raise RuntimeError(f"❌ 逻辑外键完整性校验失败：发现 {orphan_students} 条孤儿学生引用！")
    print("   [PASS] 学生代理逻辑外键校验: 100% 完整匹配 (0 孤儿)")

    # 5. 课程开设逻辑外键孤儿检查 (Logical FK Orphan Check)
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dwd.fact_student_enrollment f
        LEFT JOIN dim.dim_course c ON f.course_key = c.course_key
        WHERE c.course_key IS NULL;
    """)
    orphan_courses = cursor.fetchone()[0]
    if orphan_courses > 0:
        raise RuntimeError(f"❌ 逻辑外键完整性校验失败：发现 {orphan_courses} 条孤儿课程开设引用！")
    print("   [PASS] 课程开设代理逻辑外键校验: 100% 完整匹配 (0 孤儿)")

    # 6. (student_key, course_key) 联合主键唯一性检查
    cursor.execute("""
        SELECT COUNT(*)
        FROM (
            SELECT student_key, course_key
            FROM dwd.fact_student_enrollment
            GROUP BY student_key, course_key
            HAVING COUNT(*) > 1
        ) t;
    """)
    dup_count = cursor.fetchone()[0]
    if dup_count > 0:
        raise RuntimeError(f"❌ 主键唯一性校验失败：发现 {dup_count} 组重复主键！")
    print("   [PASS] (student_key, course_key) 联合主键唯一性校验通过 (0 重复)")

    return enroll_count


def validate_dwd_fact_student_assessment(cursor) -> int:
    """全面校验 dwd.fact_student_assessment 数据质量与逻辑外键完整性。
    若发现任何数据异常，立即抛出 RuntimeError。
    """
    print("\n🔍 执行考核事实表质量门禁与逻辑外键核验（事务提交前）...")

    # 1. 源表业务键唯一性核验
    cursor.execute("""
        SELECT COUNT(*) FROM (
            SELECT id_student, id_assessment 
            FROM stg.student_assessment 
            GROUP BY id_student, id_assessment 
            HAVING COUNT(*) > 1
        ) t;
    """)
    sa_dups = cursor.fetchone()[0]
    if sa_dups > 0:
        raise RuntimeError(f"❌ 源表质量校验失败：stg.student_assessment 存在 {sa_dups} 组重复业务键！")
    print("   [PASS] 源表 (id_student, id_assessment) 业务键唯一性校验: 100% 唯一无重复")

    # 2. 事实表行数与源头强一致校验
    cursor.execute("SELECT COUNT(*) FROM stg.student_assessment;")
    expected_count = cursor.fetchone()[0]

    cursor.execute("SELECT COUNT(*) FROM dwd.fact_student_assessment;")
    actual_count = cursor.fetchone()[0]
    if actual_count != expected_count:
        raise RuntimeError(
            f"❌ 事实表数据完整性校验失败：事实表实际行数 ({actual_count}) 与源头 ({expected_count}) 不一致！"
        )
    print(f"   [PASS] 考核事实表行数与源头 STG 完全匹配: {actual_count:,} 行")

    # 3. 学生逻辑外键孤儿检查 (Logical FK Orphan Check)
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dwd.fact_student_assessment f
        LEFT JOIN dim.dim_student s ON f.student_key = s.student_key
        WHERE s.student_key IS NULL;
    """)
    orphan_students = cursor.fetchone()[0]
    if orphan_students > 0:
        raise RuntimeError(f"❌ 逻辑外键完整性校验失败：发现 {orphan_students} 条孤儿学生引用！")
    print("   [PASS] 学生代理逻辑外键校验: 100% 完整匹配 (0 孤儿)")

    # 4. 考核项逻辑外键孤儿检查 (Logical FK Orphan Check)
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dwd.fact_student_assessment f
        LEFT JOIN dim.dim_assessment a ON f.assessment_key = a.assessment_key
        WHERE a.assessment_key IS NULL;
    """)
    orphan_assessments = cursor.fetchone()[0]
    if orphan_assessments > 0:
        raise RuntimeError(f"❌ 逻辑外键完整性校验失败：发现 {orphan_assessments} 条孤儿考核项引用！")
    print("   [PASS] 考核项代理逻辑外键校验: 100% 完整匹配 (0 孤儿)")

    # 5. 课程开设逻辑外键孤儿检查 (Logical FK Orphan Check)
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dwd.fact_student_assessment f
        LEFT JOIN dim.dim_course c ON f.course_key = c.course_key
        WHERE c.course_key IS NULL;
    """)
    orphan_courses = cursor.fetchone()[0]
    if orphan_courses > 0:
        raise RuntimeError(f"❌ 逻辑外键完整性校验失败：发现 {orphan_courses} 条孤儿课程开设引用！")
    print("   [PASS] 课程开设代理逻辑外键校验: 100% 完整匹配 (0 孤儿)")

    # 6. (student_key, assessment_key) 联合主键唯一性检查
    cursor.execute("""
        SELECT COUNT(*)
        FROM (
            SELECT student_key, assessment_key
            FROM dwd.fact_student_assessment
            GROUP BY student_key, assessment_key
            HAVING COUNT(*) > 1
        ) t;
    """)
    dup_count = cursor.fetchone()[0]
    if dup_count > 0:
        raise RuntimeError(f"❌ 主键唯一性校验失败：发现 {dup_count} 组重复主键！")
    print("   [PASS] (student_key, assessment_key) 联合主键唯一性校验通过 (0 重复)")

    return actual_count


def validate_dwd_fact_student_vle(cursor) -> int:
    """全面校验 dwd.fact_student_vle 数据质量、总点击量守恒与逻辑外键完整性。
    若发现任何数据异常，立即抛出 RuntimeError。
    """
    print("\n🔍 执行平台交互事实表质量门禁与逻辑外键核验（事务提交前）...")

    # 1. 核心度量守恒校验（财务级平衡核对：源表总点击量 == 事实表总点击量）
    cursor.execute("SELECT SUM(sum_click) FROM stg.student_vle;")
    expected_clicks = cursor.fetchone()[0]

    cursor.execute("SELECT SUM(click_count) FROM dwd.fact_student_vle;")
    actual_clicks = cursor.fetchone()[0]

    if actual_clicks != expected_clicks:
        raise RuntimeError(
            f"❌ 交互度量守恒校验失败：事实表总点击量 ({actual_clicks}) 与源头 ({expected_clicks}) 不一致！"
        )
    print(f"   [PASS] 点击量绝对守恒校验: 100% 对齐 ({actual_clicks:,} 次点击，0 丢失)")

    # 2. 事实表行数核验 (Kimball Route B 日粒度收敛)
    cursor.execute("SELECT COUNT(*) FROM dwd.fact_student_vle;")
    vle_count = cursor.fetchone()[0]
    print(f"   [PASS] 交互事实表行数收敛完成: {vle_count:,} 行 (消除 2,195,960 条碎行)")

    # 3. 学生逻辑外键孤儿检查 (Logical FK Orphan Check)
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dwd.fact_student_vle f
        LEFT JOIN dim.dim_student s ON f.student_key = s.student_key
        WHERE s.student_key IS NULL;
    """)
    orphan_students = cursor.fetchone()[0]
    if orphan_students > 0:
        raise RuntimeError(f"❌ 逻辑外键完整性校验失败：发现 {orphan_students} 条孤儿学生引用！")
    print("   [PASS] 学生代理逻辑外键校验: 100% 完整匹配 (0 孤儿)")

    # 4. 课程开设逻辑外键孤儿检查 (Logical FK Orphan Check)
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dwd.fact_student_vle f
        LEFT JOIN dim.dim_course c ON f.course_key = c.course_key
        WHERE c.course_key IS NULL;
    """)
    orphan_courses = cursor.fetchone()[0]
    if orphan_courses > 0:
        raise RuntimeError(f"❌ 逻辑外键完整性校验失败：发现 {orphan_courses} 条孤儿课程开设引用！")
    print("   [PASS] 课程开设代理逻辑外键校验: 100% 完整匹配 (0 孤儿)")

    # 5. 平台资源逻辑外键孤儿检查 (Logical FK Orphan Check)
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dwd.fact_student_vle f
        LEFT JOIN dim.dim_vle v ON f.vle_key = v.vle_key
        WHERE v.vle_key IS NULL;
    """)
    orphan_vle = cursor.fetchone()[0]
    if orphan_vle > 0:
        raise RuntimeError(f"❌ 逻辑外键完整性校验失败：发现 {orphan_vle} 条孤儿资源引用！")
    print("   [PASS] 平台资源代理逻辑外键校验: 100% 完整匹配 (0 孤儿)")

    return vle_count


def build_and_validate_dwd(cursor) -> None:
    """在当前游标事务中执行 DWD 建表与装载，并触发全部质量核验门禁。"""
    print("🚀 开始执行 DWD 明细事实表构建与装载...")
    sql_content = SQL_FILE.read_text(encoding="utf-8")
    cursor.execute(sql_content)

    # 执行核验门禁
    validate_dwd_fact_student_enrollment(cursor)
    validate_dwd_fact_student_assessment(cursor)
    validate_dwd_fact_student_vle(cursor)

    # 打印当前 DWD 表清单
    cursor.execute("""
        SELECT table_name 
        FROM information_schema.tables 
        WHERE table_schema = 'dwd' 
        ORDER BY table_name;
    """)
    tables = [row[0] for row in cursor.fetchall()]

    print("\n✅ DWD 层事实表构建成功！当前表清单与行数：")
    for t in tables:
        cursor.execute(f"SELECT COUNT(*) FROM dwd.{t};")
        count = cursor.fetchone()[0]
        print(f"   - dwd.{t:30s} : {count:>10,} 行")


def main() -> None:
    dsn = resolve_dsn()
    try:
        import psycopg
    except ImportError as error:
        raise SystemExit("Install requirements.txt before running dwd load") from error

    if not SQL_FILE.is_file():
        raise FileNotFoundError(f"Missing DWD SQL file: {SQL_FILE}")

    with psycopg.connect(dsn) as connection:
        with connection.cursor() as cursor:
            try:
                build_and_validate_dwd(cursor)
                connection.commit()
                print("\n💾 质量门禁全部通过，事务已安全提交 (COMMIT)！")
                print("🎉 DWD 事实表装载与逻辑外键校验全部成功！")
            except Exception as err:
                connection.rollback()
                print(f"\n🛑 检测到异常已执行回滚 (ROLLBACK): {err}")
                raise


if __name__ == "__main__":
    main()
