"""Execute Data Warehouse Summary (DWS) SQL to build summary tables and perform pre-commit validations."""

from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL_FILE = ROOT / "sql" / "create_dws.sql"


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


def validate_dws_student_course_summary(cursor) -> None:
    """全面校验 dws.student_course_summary 数据质量、指标守恒、状态划分与估算分空值理性。
    若发现任何数据异常，立即抛出 RuntimeError 并自动回滚。
    """
    print("\n🔍 执行 DWS 装载前置数据质量门禁与指标守恒核验（事务提交前）...")

    # 1. 声明粒度行数与选课事实主表绝对对齐校验
    cursor.execute("SELECT COUNT(*) FROM dwd.fact_student_enrollment;")
    expected_rows = cursor.fetchone()[0]

    cursor.execute("SELECT COUNT(*) FROM dws.student_course_summary;")
    dws_rows = cursor.fetchone()[0]

    if dws_rows != expected_rows:
        raise RuntimeError(
            f"❌ 行数校验失败：DWS 表行数 ({dws_rows:,}) 与选课事实主表 ({expected_rows:,}) 不一致！"
        )
    print(f"   [PASS] 声明粒度对齐校验: 精确对齐选课主干 ({dws_rows:,} 行)")

    # 2. 联合主键唯一性校验 (student_key, course_key)
    cursor.execute("""
        SELECT COUNT(*) - COUNT(DISTINCT (student_key, course_key))
        FROM dws.student_course_summary;
    """)
    pk_dups = cursor.fetchone()[0]
    if pk_dups != 0:
        raise RuntimeError(f"❌ 主键唯一性校验失败：存在 {pk_dups} 组重复复合主键！")
    print("   [PASS] 联合主键唯一性校验: (student_key, course_key) 100% 唯一")

    # 3. 平台点击量总量绝对守恒校验 (Conservation of Total Clicks)
    cursor.execute("SELECT SUM(click_count) FROM dwd.fact_student_vle;")
    dwd_clicks = cursor.fetchone()[0]

    cursor.execute("SELECT SUM(total_vle_clicks) FROM dws.student_course_summary;")
    dws_clicks = cursor.fetchone()[0]

    if dwd_clicks != dws_clicks:
        raise RuntimeError(
            f"❌ 点击量守恒校验失败：DWD 总点击 ({dwd_clicks:,}) 与 DWS 汇总 ({dws_clicks:,}) 不一致！"
        )
    print(f"   [PASS] VLE 点击量绝对守恒校验: {dws_clicks:,} 次点击 100% 精确守恒")

    # 4. 考核记录总数绝对守恒校验 (Conservation of Assessment Records)
    cursor.execute("SELECT COUNT(*) FROM dwd.fact_student_assessment;")
    dwd_assessments = cursor.fetchone()[0]

    cursor.execute("SELECT SUM(assessment_record_count) FROM dws.student_course_summary;")
    dws_assessments = cursor.fetchone()[0]

    if dwd_assessments != dws_assessments:
        raise RuntimeError(
            f"❌ 考核记录守恒校验失败：DWD 总考核记录 ({dwd_assessments:,}) 与 DWS 汇总 ({dws_assessments:,}) 不一致！"
        )
    print(f"   [PASS] 考核记录绝对守恒校验: {dws_assessments:,} 条记录 100% 精确守恒")

    # 5. 迟交指标可加性与逻辑合理性校验
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dws.student_course_summary 
        WHERE late_assessment_count > late_eligible_count;
    """)
    late_violations = cursor.fetchone()[0]
    if late_violations != 0:
        raise RuntimeError(
            f"❌ 迟交逻辑校验失败：发现 {late_violations} 条记录的迟交数大于可迟交基数！"
        )
    print("   [PASS] 迟交指标合法性校验: late_assessment_count <= late_eligible_count 100% 成立")

    # 6. 评分状态枚举与空值理性断言 (Score Status & NULL Integrity)
    cursor.execute("""
        SELECT 
            COUNT(*) FILTER (WHERE score_status NOT IN ('NO_SCORE', 'PARTIAL_SCORE', 'COMPLETE_SCORE')),
            COUNT(*) FILTER (WHERE score_rule_type NOT IN ('HYBRID_50_50', 'CA_WEIGHTED', 'CA_EQUAL_AVG')),
            COUNT(*) FILTER (WHERE score_status = 'NO_SCORE' AND estimated_course_score IS NOT NULL),
            COUNT(*) FILTER (WHERE score_status != 'NO_SCORE' AND estimated_course_score IS NULL)
        FROM dws.student_course_summary;
    """)
    invalid_status, invalid_rules, no_score_not_null, score_is_null = cursor.fetchone()
    if invalid_status != 0 or invalid_rules != 0:
        raise RuntimeError("❌ 评分状态或规则类型枚举非法！")
    if no_score_not_null != 0:
        raise RuntimeError(f"❌ 估算分空值断言失败：存在 {no_score_not_null} 条无考核记录选课估算分不为 NULL！")
    if score_is_null != 0:
        raise RuntimeError(f"❌ 有考核学生空值异常：存在 {score_is_null} 条有分记录估算分为 NULL！")
    print("   [PASS] 考核完成状态与空值理性断言: NO_SCORE 100% 为 NULL，有成绩选课 100% 赋估算分")

    # 7. 考核完成状态业务逻辑一致性双向核验 (COMPLETE_SCORE 必须满足考纲平时项与期末考全部有分)
    cursor.execute("""
        WITH cte_syllabus AS (
            SELECT code_module, code_presentation,
                   COUNT(CASE WHEN assessment_type != 'Exam' THEN 1 END) AS ca_count
            FROM dim.dim_assessment
            GROUP BY code_module, code_presentation
        ),
        cte_student_ca AS (
            SELECT f.student_key, f.course_key,
                   COUNT(CASE WHEN a.assessment_type != 'Exam' AND f.score IS NOT NULL THEN 1 END) AS scored_ca_count,
                   MAX(CASE WHEN a.assessment_type = 'Exam' THEN f.score END) AS exam_score
            FROM dwd.fact_student_assessment f
            JOIN dim.dim_assessment a ON f.assessment_key = a.assessment_key
            GROUP BY f.student_key, f.course_key
        )
        SELECT 
            COUNT(*) FILTER (
                WHERE dws.score_status = 'COMPLETE_SCORE'
                  AND (
                      COALESCE(sca.scored_ca_count, 0) < syl.ca_count
                      OR (c.code_module IN ('CCC', 'DDD') AND sca.exam_score IS NULL)
                  )
            ),
            COUNT(*) FILTER (
                WHERE dws.score_status = 'PARTIAL_SCORE'
                  AND COALESCE(sca.scored_ca_count, 0) >= syl.ca_count
                  AND (c.code_module NOT IN ('CCC', 'DDD') OR sca.exam_score IS NOT NULL)
            )
        FROM dws.student_course_summary dws
        JOIN dim.dim_course c ON dws.course_key = c.course_key
        JOIN cte_syllabus syl ON c.code_module = syl.code_module AND c.code_presentation = syl.code_presentation
        LEFT JOIN cte_student_ca sca ON dws.student_key = sca.student_key AND dws.course_key = sca.course_key;
    """)
    mislabeled_complete, mislabeled_partial = cursor.fetchone()
    if mislabeled_complete > 0:
        raise RuntimeError(f"❌ 发现 {mislabeled_complete} 条 COMPLETE_SCORE 误标记录（平时项缺分或缺期末考）！")
    if mislabeled_partial > 0:
        raise RuntimeError(f"❌ 发现 {mislabeled_partial} 条 PARTIAL_SCORE 误标记录（已满足完整标准）！")
    print("   [PASS] 考核完成状态业务双向核验: COMPLETE_SCORE 与 PARTIAL_SCORE 100% 契合考纲与期末考状态")

    # 8. 估算学术分与平时加权分区间校验 ([0.00, 100.00] 规范区间)
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dws.student_course_summary 
        WHERE ca_weighted_score < 0.00 OR ca_weighted_score > 100.00;
    """)
    ca_violations = cursor.fetchone()[0]
    if ca_violations != 0:
        raise RuntimeError(
            f"❌ 平时加权分越界校验失败：发现 {ca_violations} 条记录超出 [0, 100] 区间！"
        )

    cursor.execute("""
        SELECT COUNT(*) 
        FROM dws.student_course_summary 
        WHERE estimated_course_score IS NOT NULL 
          AND (estimated_course_score < 0.00 OR estimated_course_score > 100.00);
    """)
    score_violations = cursor.fetchone()[0]
    if score_violations != 0:
        raise RuntimeError(
            f"❌ 规则估算分越界校验失败：发现 {score_violations} 条记录超出 [0, 100] 区间！"
        )

    cursor.execute("""
        SELECT COUNT(*) 
        FROM dws.student_course_summary 
        WHERE exam_score IS NOT NULL AND (exam_score < 0.00 OR exam_score > 100.00);
    """)
    exam_violations = cursor.fetchone()[0]
    if exam_violations != 0:
        raise RuntimeError(
            f"❌ 期末考卷面分越界校验失败：发现 {exam_violations} 条记录超出 [0, 100] 区间！"
        )
    print("   [PASS] 成绩规范区间校验: estimated_course_score 与 ca_weighted_score 100% 在 [0, 100] 区间")

    # 9. 逻辑外键与非空约束完整性校验
    cursor.execute("""
        SELECT 
            COUNT(*) FILTER (WHERE student_key IS NULL OR course_key IS NULL),
            COUNT(*) FILTER (WHERE id_student IS NULL OR code_module IS NULL OR code_presentation IS NULL)
        FROM dws.student_course_summary;
    """)
    null_keys, null_nats = cursor.fetchone()
    if null_keys > 0 or null_nats > 0:
        raise RuntimeError("❌ 键完整性校验失败：主键或业务自然键存在 NULL 缺失！")

    cursor.execute("""
        SELECT COUNT(*) 
        FROM dws.student_course_summary s
        LEFT JOIN dim.dim_student ds ON s.student_key = ds.student_key
        WHERE ds.student_key IS NULL;
    """)
    orphan_students = cursor.fetchone()[0]
    if orphan_students > 0:
        raise RuntimeError(f"❌ 逻辑外键完整性校验失败：发现 {orphan_students} 条孤儿学生引用！")

    cursor.execute("""
        SELECT COUNT(*) 
        FROM dws.student_course_summary s
        LEFT JOIN dim.dim_course dc ON s.course_key = dc.course_key
        WHERE dc.course_key IS NULL;
    """)
    orphan_courses = cursor.fetchone()[0]
    if orphan_courses > 0:
        raise RuntimeError(f"❌ 逻辑外键完整性校验失败：发现 {orphan_courses} 条孤儿课程开设引用！")
    print("   [PASS] 逻辑外键与自然键完整性校验: 100% 完整匹配 (0 孤儿)")


def validate_dws_student_lifetime_summary(cursor) -> None:
    """全面校验 dws.student_lifetime_summary 数据质量、跨课程指标守恒与天数合理性。
    若发现任何数据异常，立即抛出 RuntimeError 并自动回滚。
    """
    print("\n🔍 执行 dws.student_lifetime_summary 前置数据质量门禁（事务提交前）...")

    # 1. 声明粒度行数与学生维表绝对对齐校验
    cursor.execute("SELECT COUNT(*) FROM dim.dim_student;")
    expected_rows = cursor.fetchone()[0]

    cursor.execute("SELECT COUNT(*) FROM dws.student_lifetime_summary;")
    lifetime_rows = cursor.fetchone()[0]

    if lifetime_rows != expected_rows:
        raise RuntimeError(
            f"❌ 行数校验失败：Lifetime 表行数 ({lifetime_rows:,}) 与学生维表 ({expected_rows:,}) 不一致！"
        )
    print(f"   [PASS] 声明粒度对齐校验: 精确对齐独立学生主体 ({lifetime_rows:,} 行)")

    # 2. 代理主键唯一性校验 (student_key)
    cursor.execute("""
        SELECT COUNT(*) - COUNT(DISTINCT student_key)
        FROM dws.student_lifetime_summary;
    """)
    pk_dups = cursor.fetchone()[0]
    if pk_dups != 0:
        raise RuntimeError(f"❌ 主键唯一性校验失败：存在 {pk_dups} 组重复 student_key！")
    print("   [PASS] 代理主键唯一性校验: student_key 100% 唯一")

    # 3. 选课总门数守恒校验
    cursor.execute("SELECT COUNT(*) FROM dws.student_course_summary;")
    course_summary_rows = cursor.fetchone()[0]

    cursor.execute("SELECT SUM(total_courses_enrolled) FROM dws.student_lifetime_summary;")
    lifetime_courses = cursor.fetchone()[0]

    if lifetime_courses != course_summary_rows:
        raise RuntimeError(
            f"❌ 选课门数守恒失败：单科表记录数 ({course_summary_rows:,}) 与生涯累积 ({lifetime_courses:,}) 不一致！"
        )
    print(f"   [PASS] 选课门数守恒校验: {lifetime_courses:,} 门选课记录 100% 精确守恒")

    # 4. 平台总点击量绝对守恒校验
    cursor.execute("SELECT SUM(click_count) FROM dwd.fact_student_vle;")
    dwd_clicks = cursor.fetchone()[0]

    cursor.execute("SELECT SUM(lifetime_total_clicks) FROM dws.student_lifetime_summary;")
    lifetime_clicks = cursor.fetchone()[0]

    if lifetime_clicks != dwd_clicks:
        raise RuntimeError(
            f"❌ 点击量守恒校验失败：DWD 总点击 ({dwd_clicks:,}) 与 Lifetime 汇总 ({lifetime_clicks:,}) 不一致！"
        )
    print(f"   [PASS] 全生涯点击量绝对守恒校验: {lifetime_clicks:,} 次点击 100% 精确守恒")

    # 5. 跨课程选课状态逻辑守恒检验
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dws.student_lifetime_summary 
        WHERE (total_courses_passed + total_courses_withdrawn + total_courses_failed) != total_courses_enrolled;
    """)
    status_violations = cursor.fetchone()[0]
    if status_violations != 0:
        raise RuntimeError(
            f"❌ 选课状态收敛失败：发现 {status_violations} 条记录的 (通过+退课+挂科) != 总修课数！"
        )
    print("   [PASS] 选课状态收敛一致性校验: (通过+退课+挂科) == 总修课数 100% 成立")

    # 6. 活跃天数合理性断言: 客观累加天数 sum_course_active_days >= 锚定推算去重天数 anchored_lifetime_active_days
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dws.student_lifetime_summary 
        WHERE sum_course_active_days < anchored_lifetime_active_days;
    """)
    days_violations = cursor.fetchone()[0]
    if days_violations != 0:
        raise RuntimeError(
            f"❌ 活跃天数去重合理性失败：发现 {days_violations} 条记录各门课累加天数小于去重天数！"
        )
    print("   [PASS] 活跃天数合理性断言: 各门课累加天数 >= 锚定推算去重天数 100% 成立")

    # 7. 逻辑外键与自然键完整性
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dws.student_lifetime_summary l
        LEFT JOIN dim.dim_student s ON l.student_key = s.student_key
        WHERE s.student_key IS NULL;
    """)
    orphan_students = cursor.fetchone()[0]
    if orphan_students > 0:
        raise RuntimeError(f"❌ 逻辑外键完整性校验失败：发现 {orphan_students} 条孤儿学生引用！")
    print("   [PASS] 逻辑外键与自然键完整性校验: 100% 完整匹配 (0 孤儿)")


def validate_dws_course_presentation_summary(cursor) -> None:
    """全面校验 dws.course_presentation_summary 数据质量、班级规模与点击量守恒。
    若发现任何数据异常，立即抛出 RuntimeError 并自动回滚。
    """
    print("\n🔍 执行 dws.course_presentation_summary 前置数据质量门禁（事务提交前）...")

    # 1. 声明粒度行数与课程维表绝对对齐校验
    cursor.execute("SELECT COUNT(*) FROM dim.dim_course;")
    expected_rows = cursor.fetchone()[0]

    cursor.execute("SELECT COUNT(*) FROM dws.course_presentation_summary;")
    presentation_rows = cursor.fetchone()[0]

    if presentation_rows != expected_rows:
        raise RuntimeError(
            f"❌ 行数校验失败：开课表行数 ({presentation_rows:,}) 与课程维表 ({expected_rows:,}) 不一致！"
        )
    print(f"   [PASS] 声明粒度对齐校验: 精确对齐开课班次主体 ({presentation_rows:,} 行)")

    # 2. 代理主键唯一性校验 (course_key)
    cursor.execute("""
        SELECT COUNT(*) - COUNT(DISTINCT course_key)
        FROM dws.course_presentation_summary;
    """)
    pk_dups = cursor.fetchone()[0]
    if pk_dups != 0:
        raise RuntimeError(f"❌ 主键唯一性校验失败：存在 {pk_dups} 组重复 course_key！")
    print("   [PASS] 代理主键唯一性校验: course_key 100% 唯一")

    # 3. 选课总人次绝对守恒校验
    cursor.execute("SELECT COUNT(*) FROM dws.student_course_summary;")
    expected_enrollments = cursor.fetchone()[0]

    cursor.execute("SELECT SUM(total_enrolled_students) FROM dws.course_presentation_summary;")
    actual_enrollments = cursor.fetchone()[0]

    if actual_enrollments != expected_enrollments:
        raise RuntimeError(
            f"❌ 选课人次守恒失败：单科表记录数 ({expected_enrollments:,}) 与开课班次汇总 ({actual_enrollments:,}) 不一致！"
        )
    print(f"   [PASS] 选课人次绝对守恒校验: {actual_enrollments:,} 人次 100% 精确守恒")

    # 4. 平台总点击量绝对守恒校验
    cursor.execute("SELECT SUM(click_count) FROM dwd.fact_student_vle;")
    dwd_clicks = cursor.fetchone()[0]

    cursor.execute("SELECT SUM(total_vle_clicks) FROM dws.course_presentation_summary;")
    presentation_clicks = cursor.fetchone()[0]

    if presentation_clicks != dwd_clicks:
        raise RuntimeError(
            f"❌ 点击量守恒校验失败：DWD 总点击 ({dwd_clicks:,}) 与开课汇总 ({presentation_clicks:,}) 不一致！"
        )
    print(f"   [PASS] 平台点击量绝对守恒校验: {presentation_clicks:,} 次点击 100% 精确守恒")

    # 5. 班级学生状态收敛逻辑检验
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dws.course_presentation_summary 
        WHERE (total_passed_students + total_withdrawn_students + total_failed_students) != total_enrolled_students;
    """)
    status_violations = cursor.fetchone()[0]
    if status_violations != 0:
        raise RuntimeError(
            f"❌ 学生状态收敛失败：发现 {status_violations} 条记录的 (通过+退课+挂科) != 总选课人数！"
        )
    print("   [PASS] 班级学生状态收敛校验: (通过+退课+挂科) == 总选课人数 100% 成立")

    # 6. 均分阶梯理性断言: 有成绩学生均分 >= 全员按0估算均分
    cursor.execute("""
        SELECT COUNT(*) 
        FROM dws.course_presentation_summary 
        WHERE avg_scored_estimated_score < avg_enrolled_estimated_score;
    """)
    score_violations = cursor.fetchone()[0]
    if score_violations != 0:
        raise RuntimeError(
            f"❌ 班级均分阶梯异常：发现 {score_violations} 条记录有成绩均分反常低于全员按0均分！"
        )
    print("   [PASS] 班级估算均分阶梯断言: 有成绩学生均分 >= 全员估算均分 100% 成立")


def print_dws_analytics_summary(cursor) -> None:
    """输出 DWS 汇总宽表的核心指标画像概览。"""
    print("\n📊 1. dws.student_course_summary（单科汇总表）关键业务画像：")
    cursor.execute("""
        SELECT 
            COUNT(*) AS total_enrollments,
            COUNT(estimated_course_score) AS scored_enrollments,
            ROUND(COUNT(estimated_course_score)::numeric / COUNT(*) * 100, 2) AS score_coverage_pct,
            COUNT(CASE WHEN final_result IN ('Pass', 'Distinction') THEN 1 END) AS pass_count,
            ROUND(COUNT(CASE WHEN final_result IN ('Pass', 'Distinction') THEN 1 END)::numeric / COUNT(*) * 100, 2) AS pass_rate,
            COUNT(CASE WHEN final_result = 'Withdrawn' THEN 1 END) AS withdrawn_count,
            ROUND(COUNT(CASE WHEN final_result = 'Withdrawn' THEN 1 END)::numeric / COUNT(*) * 100, 2) AS withdrawn_rate,
            ROUND(AVG(total_vle_clicks), 1) AS avg_student_clicks,
            ROUND(AVG(active_vle_days), 1) AS avg_active_days,
            ROUND(AVG(visited_vle_resources), 1) AS avg_visited_resources,
            ROUND(AVG(ca_weighted_score), 2) AS avg_ca_score,
            ROUND(AVG(estimated_course_score), 2) AS avg_scored_estimated_score,
            ROUND(AVG(COALESCE(estimated_course_score, 0.00)), 2) AS avg_enrolled_estimated_score,
            ROUND(AVG(exam_score), 2) AS avg_exam_score
        FROM dws.student_course_summary;
    """)
    row = cursor.fetchone()
    print(f"   - 总选课人次数 (Total Enrollments)    : {row[0]:,}")
    print(f"   - 至少单项有分人次 (Scored Enrollments): {row[1]:,} ({row[2]}%) | 无评分(置NULL)人次: {row[0]-row[1]:,}")
    print(f"   - 全员选课通过率 (Enrolled Pass Rate) : {row[4]}% ({row[3]:,} 人)")
    print(f"   - 单科退课率 (Withdrawn Rate)         : {row[6]}% ({row[5]:,} 人)")
    print(f"   - 生均平台点击量 (Avg Clicks)          : {row[7]:,} 次")
    print(f"   - 生均实际上线天数 (Avg Active Days)   : {row[8]} 天")
    print(f"   - 生均访问资源数 (Avg Visited Items)   : {row[9]} 项")
    print(f"   - 平时作业加权均分 (Avg CA Score)      : {row[10]} 分 (满分 100)")
    print(f"   - 有成绩学生估算均分 (Avg Scored Score): {row[11]} 分 (满分 100，排除 NULL)")
    print(f"   - 全员缺分按0估算均分 (Avg Enrolled)   : {row[12]} 分 (含缺考按 0 折算)")
    print(f"   - 参加期末考卷面均分 (Avg Exam Score)  : {row[13]} 分")

    print("\n📊 2. dws.student_lifetime_summary（学生全生命周期 360 表）关键业务画像：")
    cursor.execute("""
        SELECT 
            COUNT(*) AS total_students,
            COUNT(CASE WHEN total_courses_enrolled > 1 THEN 1 END) AS multi_course_students,
            ROUND(AVG(total_courses_enrolled), 2) AS avg_courses_per_student,
            ROUND(AVG(avg_course_estimated_score), 2) AS avg_scored_estimated_score,
            ROUND(AVG(avg_enrolled_estimated_score), 2) AS avg_enrolled_estimated_score,
            ROUND(AVG(lifetime_total_clicks), 1) AS avg_lifetime_clicks,
            ROUND(AVG(sum_course_active_days), 1) AS avg_sum_active_days,
            ROUND(AVG(anchored_lifetime_active_days), 1) AS avg_anchored_active_days
        FROM dws.student_lifetime_summary;
    """)
    row2 = cursor.fetchone()
    print(f"   - 独立学生总人数 (Total Students)     : {row2[0]:,}")
    print(f"   - 修读多门课学生数 (Multi-course)     : {row2[1]:,} 人")
    print(f"   - 人均选课门数 (Avg Enrolled Courses) : {row2[2]} 门")
    print(f"   - 所修有分课程平均估算分 (Scored)     : {row2[3]} 分 (非官方 GPA)")
    print(f"   - 全部选课平均估算分 (All Enrolled)   : {row2[4]} 分 (缺考按 0)")
    print(f"   - 生均大学总点击量 (Avg Total Clicks) : {row2[5]:,} 次")
    print(f"   - 各门课活跃天数客观累加均值 (Sum Days): {row2[6]} 天")
    print(f"   - 学期锚定推算去重活跃天数 (Anchored) : {row2[7]} 天 (估算自然日)")

    print("\n📊 3. dws.course_presentation_summary（开课班次运营成效表）关键业务画像：")
    cursor.execute("""
        SELECT 
            COUNT(*) AS total_presentations,
            ROUND(AVG(total_enrolled_students), 1) AS avg_class_size,
            ROUND(SUM(total_passed_students)::numeric / SUM(total_enrolled_students) * 100, 2) AS macro_pass_rate,
            ROUND(SUM(total_withdrawn_students)::numeric / SUM(total_enrolled_students) * 100, 2) AS macro_withdrawn_rate,
            ROUND(AVG(avg_scored_estimated_score), 2) AS avg_scored_class_score,
            ROUND(AVG(avg_enrolled_estimated_score), 2) AS avg_enrolled_class_score,
            ROUND(SUM(content_clicks)::numeric / SUM(total_vle_clicks) * 100, 2) AS content_click_pct,
            ROUND(SUM(forum_clicks)::numeric / SUM(total_vle_clicks) * 100, 2) AS forum_click_pct,
            ROUND(SUM(quiz_clicks)::numeric / SUM(total_vle_clicks) * 100, 2) AS quiz_click_pct
        FROM dws.course_presentation_summary;
    """)
    row3 = cursor.fetchone()
    print(f"   - 开课班次总数 (Total Presentations) : {row3[0]:,} 个")
    print(f"   - 平均班级规模 (Avg Class Size)      : {row3[1]} 人")
    print(f"   - 全校大盘综合通过率 (Macro Pass Rate): {row3[2]}%")
    print(f"   - 全校大盘综合退课率 (Withdrawn Rate) : {row3[3]}%")
    print(f"   - 开课班级有成绩估算均分 (Scored)     : {row3[4]} 分")
    print(f"   - 开课班级全员缺考按0估算均分 (Enrolled): {row3[5]} 分")
    print(f"   - 教材课件点击结构占比 (Content)      : {row3[6]}%")
    print(f"   - 论坛社群点击结构占比 (Forum)        : {row3[7]}%")
    print(f"   - 在线测验点击结构占比 (Quiz)         : {row3[8]}%")


def build_and_validate_dws(cursor) -> None:
    """在当前事务中执行 DWS 建表、装载与质量门禁。"""
    print("🚀 开始执行 DWS 服务/轻度汇总表构建与装载...")
    sql_content = SQL_FILE.read_text(encoding="utf-8")
    cursor.execute(sql_content)

    # 执行核验门禁
    validate_dws_student_course_summary(cursor)
    validate_dws_student_lifetime_summary(cursor)
    validate_dws_course_presentation_summary(cursor)

    # 打印业务统计画像
    print_dws_analytics_summary(cursor)


def main() -> None:
    dsn = resolve_dsn()
    try:
        import psycopg
    except ImportError as error:
        raise SystemExit("Install requirements.txt before running dws load") from error

    if not SQL_FILE.is_file():
        raise FileNotFoundError(f"Missing DWS SQL file: {SQL_FILE}")

    with psycopg.connect(dsn) as connection:
        with connection.cursor() as cursor:
            try:
                build_and_validate_dws(cursor)
                connection.commit()
                print("\n💾 质量门禁全部通过，事务已安全提交 (COMMIT)！")
                print("🎉 DWS 轻度汇总宽表装载与指标校验全部成功！")
            except Exception as err:
                connection.rollback()
                print(f"\n🛑 检测到异常已执行回滚 (ROLLBACK): {err}")
                raise


if __name__ == "__main__":
    main()
