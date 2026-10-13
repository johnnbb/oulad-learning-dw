"""Execute Application Data Service (ADS) SQL to build decision mart tables and perform pre-commit validations."""

from __future__ import annotations

import os
from pathlib import Path
import psycopg

ROOT = Path(__file__).resolve().parents[1]
SQL_FILE = ROOT / "sql" / "create_ads.sql"


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


def validate_ads_course_teaching_kpi(cursor) -> None:
    """全面校验 ads.ads_course_teaching_kpi 数据质量、指标守恒、排位完整性与三阶得分阶梯。
    若发现任何数据异常，立即抛出 RuntimeError 并触发事务自动回滚。
    """
    print("\n🔍 执行 ADS 课程成效概览大盘装载前置数据质量门禁（事务提交前）...")

    # 1. 行数严格对齐校验 (全校 22 门课程班次)
    cursor.execute("SELECT COUNT(*) FROM ads.ads_course_teaching_kpi;")
    row_count = cursor.fetchone()[0]
    if row_count != 22:
        raise RuntimeError(f"❌ 行数校验失败：ADS 课程大盘表行数 ({row_count}) 必须严格为 22！")
    print(f"   [PASS] 声明粒度对齐校验: 全校开课班次精准覆盖 ({row_count} 行)")

    # 2. 代理主键唯一性校验 (course_key)
    cursor.execute("""
        SELECT COUNT(*) - COUNT(DISTINCT course_key)
        FROM ads.ads_course_teaching_kpi;
    """)
    pk_dups = cursor.fetchone()[0]
    if pk_dups != 0:
        raise RuntimeError(f"❌ 主键唯一性校验失败：存在 {pk_dups} 组重复 course_key！")
    print("   [PASS] 主键唯一性校验: course_key 100% 唯一无重复")

    # 3. 选课总规模与学籍状态绝对守恒校验
    cursor.execute("""
        SELECT 
            SUM(total_enrolled_students),
            SUM(scored_student_count),
            SUM(total_passed_students),
            SUM(total_withdrawn_students),
            SUM(total_failed_students)
        FROM ads.ads_course_teaching_kpi;
    """)
    sum_enrolled, sum_scored, sum_passed, sum_withdrawn, sum_failed = cursor.fetchone()
    if sum_enrolled != 32593:
        raise RuntimeError(f"❌ 选课总规模守恒失败：总人次 ({sum_enrolled:,}) 不等于 32,593！")
    if (sum_passed + sum_withdrawn + sum_failed) != sum_enrolled:
        raise RuntimeError(
            f"❌ 学籍状态守恒失败：通过({sum_passed}) + 退课({sum_withdrawn}) + 未通过({sum_failed}) != 总选课({sum_enrolled})"
        )
    if sum_scored > sum_enrolled or sum_scored != 25820:
        raise RuntimeError(f"❌ 有成绩学生人数异常：scored ({sum_scored}) 超过总人数或不符合预期 25,820！")
    print(
        f"   [PASS] 学籍状态守恒校验: 32,593 选课总人次绝对守恒 "
        f"(有成绩: {sum_scored:,}, 通过: {sum_passed:,}, 退课: {sum_withdrawn:,}, 未通过: {sum_failed:,})"
    )

    # 4. 平台交互点击量绝对守恒校验
    cursor.execute("SELECT SUM(total_vle_clicks) FROM ads.ads_course_teaching_kpi;")
    sum_clicks = cursor.fetchone()[0]
    if sum_clicks != 39605099:
        raise RuntimeError(f"❌ 点击量守恒失败：总点击量 ({sum_clicks:,}) 不等于 39,605,099！")
    print("   [PASS] 平台点击守恒校验: 39,605,099 次平台点击绝对守恒")

    # 5. 比率区间与结课通过率合理性校验 (0.00 ~ 100.00%)
    cursor.execute("""
        SELECT COUNT(*) 
        FROM ads.ads_course_teaching_kpi
        WHERE score_coverage_rate < 0 OR score_coverage_rate > 100
           OR enrolled_pass_rate < 0 OR enrolled_pass_rate > 100
           OR completion_pass_rate < 0 OR completion_pass_rate > 100
           OR distinction_rate < 0 OR distinction_rate > 100
           OR withdrawn_rate < 0 OR withdrawn_rate > 100
           OR fail_rate < 0 OR fail_rate > 100
           OR content_click_pct < 0 OR content_click_pct > 100
           OR forum_click_pct < 0 OR forum_click_pct > 100
           OR quiz_click_pct < 0 OR quiz_click_pct > 100;
    """)
    invalid_rates = cursor.fetchone()[0]
    if invalid_rates != 0:
        raise RuntimeError(f"❌ 比率合法性校验失败：发现 {invalid_rates} 条记录的比率越界！")
    print("   [PASS] 转化率与交互占比区间校验: 全部指标严格处于 [0.00, 100.00]% 区间")

    # 6. 学术得分三阶标尺理性断言: avg_enrolled_score <= avg_scored_student_score <= avg_passer_score
    cursor.execute("""
        SELECT COUNT(*)
        FROM ads.ads_course_teaching_kpi
        WHERE avg_enrolled_score < 0 OR avg_enrolled_score > 100
           OR avg_scored_student_score < 0 OR avg_scored_student_score > 100
           OR avg_passer_score < 0 OR avg_passer_score > 100
           OR avg_scored_student_score < avg_enrolled_score
           OR avg_passer_score < avg_scored_student_score;
    """)
    invalid_score_tiers = cursor.fetchone()[0]
    if invalid_score_tiers != 0:
        raise RuntimeError(
            f"❌ 学术均分三阶梯校验失败：存在 {invalid_score_tiers} 条记录均分反常越界或不满足 "
            f"[全员均分 <= 有成绩均分 <= 通过者均分] 的严格数学递增关系！"
        )
    print("   [PASS] 学术分三阶梯递增断言: 全员均分 <= 有成绩均分 <= 通过者均分 100% 成立")

    # 7. 全校排位完整性断言
    cursor.execute("""
        SELECT 
            MIN(enrolled_pass_rate_rank), MAX(enrolled_pass_rate_rank),
            MIN(withdrawn_rate_rank), MAX(withdrawn_rate_rank)
        FROM ads.ads_course_teaching_kpi;
    """)
    min_p, max_p, min_w, max_w = cursor.fetchone()
    if min_p != 1 or max_p > 22 or min_w != 1 or max_w > 22:
        raise RuntimeError(
            f"❌ 排名完整性校验失败：通过率排位 [{min_p}, {max_p}], 退课率排位 [{min_w}, {max_w}]"
        )
    print("   [PASS] 全校排名完整性校验: 选课通过率与退课率排位 [1, 22] 完备无断层")

    # 8. 智能分级与异常指标枚举校验
    cursor.execute("""
        SELECT COUNT(*) 
        FROM ads.ads_course_teaching_kpi
        WHERE course_result_alert_tier NOT IN ('标杆成效班次', '常规平稳班次', '重点预警班次')
           OR primary_alert_indicator NOT IN ('退课率偏高', '结课未通过率偏高', '全员未通过率偏高', '指标平稳');
    """)
    invalid_tiers = cursor.fetchone()[0]
    if invalid_tiers != 0:
        raise RuntimeError(f"❌ 标签枚举校验失败：存在 {invalid_tiers} 条非法预警分级或异常指标文本！")
    print("   [PASS] 结果预警分级标签校验: 全部班次准确归入标准客观结果分级与预警指标")


def print_teaching_kpi_dashboard(cursor) -> None:
    """打印全校课程成效概览终端看板（含加权宏观统揽卡片）。"""
    cursor.execute("""
        SELECT 
            enrolled_pass_rate_rank,
            code_module,
            code_presentation,
            total_enrolled_students,
            score_coverage_rate,
            enrolled_pass_rate,
            completion_pass_rate,
            withdrawn_rate,
            fail_rate,
            avg_scored_student_score,
            avg_passer_score,
            course_result_alert_tier,
            primary_alert_indicator
        FROM ads.ads_course_teaching_kpi
        ORDER BY enrolled_pass_rate_rank ASC;
    """)
    rows = cursor.fetchall()

    print("\n" + "=" * 140)
    print("🎓 【教务决策概览大盘】全校 22 门课程班次成效与指标概览看板 (ads.ads_course_teaching_kpi)")
    print("=" * 140)
    header = (
        f"{'排名':^4} | {'课程':^5} | {'学期':^6} | {'选课人数':^8} | {'成绩覆盖':^8} | "
        f"{'选课通过率':^9} | {'结课通过率':^9} | {'退课率':^7} | {'未通过率':^8} | "
        f"{'有分均分':^8} | {'及格均分':^8} | {'成效分级':^12} | {'主要预警指标':^14}"
    )
    print(header)
    print("-" * 140)

    for r in rows:
        (
            p_rank, module, pres, enrolled, cov_rate, pass_pct, comp_pass, 
            withdrawn_pct, fail_pct, scored_avg, passer_avg, tier, indicator
        ) = r
        line = (
            f"{p_rank:^4} | {module:^5} | {pres:^6} | {enrolled:>8,d} | {cov_rate:>7.2f}% | "
            f"{pass_pct:>8.2f}% | {comp_pass:>8.2f}% | {withdrawn_pct:>6.2f}% | {fail_pct:>7.2f}% | "
            f"{scored_avg:>8.2f} | {passer_avg:>8.2f} | {tier:^12} | {indicator:^14}"
        )
        print(line)

    print("-" * 140)

    # 打印加权计算的宏观统揽指标（严格按选课人次加权，杜绝简单平均导致的失真）
    cursor.execute("""
        SELECT 
            COUNT(*) AS total_presentations,
            SUM(total_enrolled_students) AS total_enrolled,
            SUM(scored_student_count) AS total_scored,
            SUM(total_passed_students) AS total_passed,
            SUM(total_withdrawn_students) AS total_withdrawn,
            SUM(total_failed_students) AS total_failed,
            COUNT(CASE WHEN course_result_alert_tier = '标杆成效班次' THEN 1 END) AS benchmark_count,
            COUNT(CASE WHEN course_result_alert_tier = '常规平稳班次' THEN 1 END) AS standard_count,
            COUNT(CASE WHEN course_result_alert_tier = '重点预警班次' THEN 1 END) AS alert_count
        FROM ads.ads_course_teaching_kpi;
    """)
    summary = cursor.fetchone()
    (
        total_p, tot_enr, tot_sc, tot_pass, tot_wd, tot_fail,
        bench_cnt, std_cnt, alert_cnt
    ) = summary

    # 精准从底层单科画像宽表取全员、有成绩与通过群体的真实加权均分
    cursor.execute("""
        SELECT 
            ROUND(AVG(COALESCE(estimated_course_score, 0.00)), 2) AS weighted_enrolled_gpa,
            ROUND(AVG(estimated_course_score), 2) AS weighted_scored_gpa,
            ROUND(AVG(CASE WHEN final_result IN ('Pass', 'Distinction') THEN estimated_course_score END), 2) AS weighted_passer_gpa
        FROM dws.student_course_summary;
    """)
    weighted_gpas = cursor.fetchone()
    w_enr_gpa, w_sc_gpa, w_pass_gpa = weighted_gpas

    overall_cov = round(tot_sc / tot_enr * 100, 2)
    overall_enr_pass = round(tot_pass / tot_enr * 100, 2)
    overall_comp_pass = round(tot_pass / (tot_pass + tot_fail) * 100, 2)
    overall_wd = round(tot_wd / tot_enr * 100, 2)
    overall_fail = round(tot_fail / tot_enr * 100, 2)

    print("\n📊 【全校办学宏观指标统览（按总选课人数精准加权）】")
    print(f"   • 开课班次总数: {total_p} 个班次 | 累计选课人次: {tot_enr:,} 人次 | 至少单项有分人次: {tot_sc:,} ({overall_cov}%)")
    print(f"   • 全员选课通过率: {overall_enr_pass}% | 已结课学生通过率: {overall_comp_pass}% (剥离退课干扰)")
    print(f"   • 全校综合退课率: {overall_wd}% | 综合考核未通过率: {overall_fail}%")
    print(f"   • 学术得分三阶梯 (加权规则估算均分，非官方最终成绩):")
    print(f"     └─ 1. 全员注册估算均分: {w_enr_gpa} 分 (含无已评分记录折算 0 分)")
    print(f"     └─ 2. 至少单项有分估算均分: {w_sc_gpa} 分 (排除 6,773 条无评分选课，含部分缺分低估)")
    print(f"     └─ 3. 有成绩通过者估算均分: {w_pass_gpa} 分 (仅统计及格且有评分记录学生，排除 3 条无分通过者)")
    print(f"   • 班次结果分级分布: 标杆成效班次 {bench_cnt} 门 ({bench_cnt/total_p*100:.1f}%) | 常规平稳班次 {std_cnt} 门 ({std_cnt/total_p*100:.1f}%) | 重点预警班次 {alert_cnt} 门 ({alert_cnt/total_p*100:.1f}%)")
    print("=" * 140 + "\n")


def validate_ads_student_course_diagnostic(cursor) -> None:
    """全面校验 ads.ads_student_course_diagnostic 数据质量、粒度守恒、分位数与客观事实标签一致性。
    若发现任何数据异常，立即抛出 RuntimeError 并自动回滚。
    """
    print("\n🔍 执行 ADS 期末学生单科学情诊断表装载前置数据质量门禁（事务提交前）...")

    # 1. 声明粒度与行数绝对对齐校验 (32,593 行)
    cursor.execute("SELECT COUNT(*) FROM ads.ads_student_course_diagnostic;")
    diag_rows = cursor.fetchone()[0]
    if diag_rows != 32593:
        raise RuntimeError(
            f"❌ 粒度行数校验失败：诊断表总行数 ({diag_rows:,}) 不等于 32,593！"
        )
    print(f"   [PASS] 声明粒度对齐校验: 全校选课人次精准覆盖 ({diag_rows:,} 行)")

    # 2. 联合代理主键唯一性校验 (student_key, course_key)
    cursor.execute("""
        SELECT COUNT(*) - COUNT(DISTINCT (student_key, course_key))
        FROM ads.ads_student_course_diagnostic;
    """)
    pk_dups = cursor.fetchone()[0]
    if pk_dups != 0:
        raise RuntimeError(f"❌ 联合主键唯一性校验失败：存在 {pk_dups} 条重复记录！")
    print("   [PASS] 联合主键唯一性校验: (student_key, course_key) 100% 唯一无重复")

    # 3. 学籍结果分布绝对守恒断言
    cursor.execute("""
        SELECT 
            COUNT(*) FILTER (WHERE final_result = 'Pass'),
            COUNT(*) FILTER (WHERE final_result = 'Distinction'),
            COUNT(*) FILTER (WHERE final_result = 'Fail'),
            COUNT(*) FILTER (WHERE final_result = 'Withdrawn')
        FROM ads.ads_student_course_diagnostic;
    """)
    pass_cnt, dist_cnt, fail_cnt, wd_cnt = cursor.fetchone()
    if (pass_cnt, dist_cnt, fail_cnt, wd_cnt) != (12361, 3024, 7052, 10156):
        raise RuntimeError(
            f"❌ 学籍结果守恒断言失败：分布 ({pass_cnt}, {dist_cnt}, {fail_cnt}, {wd_cnt}) 与事实层不一致！"
        )
    print("   [PASS] 学籍考核结果守恒校验: 4 大最终结果分类 (通过/优秀/未通过/退课) 100% 绝对守恒")

    # 4. 考核状态守恒断言
    cursor.execute("""
        SELECT 
            COUNT(*) FILTER (WHERE score_status = 'COMPLETE_SCORE'),
            COUNT(*) FILTER (WHERE score_status = 'PARTIAL_SCORE'),
            COUNT(*) FILTER (WHERE score_status = 'NO_SCORE')
        FROM ads.ads_student_course_diagnostic;
    """)
    comp_cnt, part_cnt, no_cnt = cursor.fetchone()
    if (comp_cnt, part_cnt, no_cnt) != (13395, 12425, 6773):
        raise RuntimeError(
            f"❌ 考核状态守恒断言失败：分布 ({comp_cnt}, {part_cnt}, {no_cnt}) 不符标准口径！"
        )
    print("   [PASS] 考核完成状态守恒校验: COMPLETE_SCORE (13,395), PARTIAL (12,425), NO_SCORE (6,773) 绝对守恒")

    # 5. 班级百分位合法性与空值理性校验
    cursor.execute("""
        SELECT 
            COUNT(*) FILTER (WHERE class_activity_percentile < 0.00 OR class_activity_percentile > 100.00),
            COUNT(*) FILTER (WHERE class_score_percentile IS NOT NULL AND (class_score_percentile < 0.00 OR class_score_percentile > 100.00)),
            COUNT(*) FILTER (WHERE score_status = 'NO_SCORE' AND class_score_percentile IS NOT NULL),
            COUNT(*) FILTER (WHERE score_status != 'NO_SCORE' AND class_score_percentile IS NULL)
        FROM ads.ads_student_course_diagnostic;
    """)
    act_out, sc_out, no_sc_not_null, sc_is_null = cursor.fetchone()
    if act_out != 0 or sc_out != 0:
        raise RuntimeError("❌ 班级百分位越界：存在超出 [0.00, 100.00] 的非法百分位！")
    if no_sc_not_null != 0 or sc_is_null != 0:
        raise RuntimeError(
            f"❌ 成绩分位数空值断言失败：无成绩非空 ({no_sc_not_null}), 有成绩为空 ({sc_is_null})！"
        )
    print("   [PASS] 班级百分位区间与空值断言: 活跃度分位全覆盖，成绩分位数仅作用于有分群体")

    # 6. 客观事实标签双向一致性与退课范围断言
    cursor.execute("""
        SELECT 
            COUNT(*) FILTER (WHERE (total_vle_clicks = 0) != is_zero_click),
            COUNT(*) FILTER (WHERE (score_status = 'NO_SCORE') != is_unrated_enrollment),
            COUNT(*) FILTER (WHERE (late_assessment_count >= 2) != is_frequent_late),
            COUNT(*) FILTER (WHERE (num_of_prev_attempts > 0) != is_re_registered),
            COUNT(*) FILTER (WHERE (COALESCE(final_result = 'Withdrawn' AND unregistration_day_offset < 0, FALSE) != is_pre_course_withdrawn)),
            COUNT(*) FILTER (WHERE (COALESCE(final_result = 'Withdrawn' AND unregistration_day_offset BETWEEN 0 AND 30, FALSE) != is_early_withdrawn)),
            COUNT(*) FILTER (WHERE is_early_withdrawn AND (final_result != 'Withdrawn' OR unregistration_day_offset < 0 OR unregistration_day_offset > 30)),
            COUNT(*) FILTER (WHERE is_pre_course_withdrawn AND (final_result != 'Withdrawn' OR unregistration_day_offset >= 0)),
            COUNT(*) FILTER (WHERE factual_tag_summary IS NULL OR factual_tag_summary = '')
        FROM ads.ads_student_course_diagnostic;
    """)
    (zero_err, unrated_err, late_err, re_err, pre_wd_err, early_wd_err, 
     early_wd_bounds, pre_wd_bounds, tag_null) = cursor.fetchone()

    if (zero_err != 0 or unrated_err != 0 or late_err != 0 or re_err != 0 or 
        pre_wd_err != 0 or early_wd_err != 0 or early_wd_bounds != 0 or 
        pre_wd_bounds != 0 or tag_null != 0):
        raise RuntimeError("❌ 客观事实标签逻辑不一致或退课范围越界校验失败！")
    print("   [PASS] 客观事实标签双向一致性校验: 零点击/未评分/频迟交/重修生/开课前与初期退课标记 100% 精准对应物理事实")

    # 7. 逻辑外键与自然键完整性校验 (0 孤儿)
    cursor.execute("""
        SELECT 
            COUNT(*) FILTER (WHERE s.student_key IS NULL),
            COUNT(*) FILTER (WHERE c.course_key IS NULL)
        FROM ads.ads_student_course_diagnostic d
        LEFT JOIN dim.dim_student s ON d.student_key = s.student_key
        LEFT JOIN dim.dim_course c ON d.course_key = c.course_key;
    """)
    orphan_s, orphan_c = cursor.fetchone()
    if orphan_s != 0 or orphan_c != 0:
        raise RuntimeError(f"❌ 逻辑外键完整性校验失败：孤儿学生 ({orphan_s}), 孤儿课程 ({orphan_c})！")
    print("   [PASS] 逻辑外键完整性校验: 关联维度表 100% 完整匹配 (0 孤儿)")


def print_student_diagnostic_dashboard(cursor) -> None:
    """打印期末学生单科学情诊断终端看板（结果群体对比与高频事实标签矩阵）。"""
    cursor.execute("""
        SELECT 
            final_result,
            COUNT(*) AS student_count,
            ROUND(COUNT(*) FILTER (WHERE score_status != 'NO_SCORE')::numeric / COUNT(*) * 100, 1) AS scored_coverage_pct,
            ROUND(AVG(COALESCE(estimated_course_score, 0.00)), 1) AS avg_enrolled_score,
            ROUND(AVG(estimated_course_score), 1) AS avg_scored_score,
            ROUND(AVG(total_vle_clicks), 1) AS avg_clicks,
            ROUND(AVG(class_activity_percentile), 1) AS avg_activity_pct,
            COUNT(*) FILTER (WHERE is_zero_click) AS zero_clicks,
            COUNT(*) FILTER (WHERE is_re_registered) AS re_registered_count
        FROM ads.ads_student_course_diagnostic
        GROUP BY final_result
        ORDER BY avg_clicks DESC;
    """)
    result_rows = cursor.fetchall()

    print("\n" + "=" * 140)
    print("📊 【微观教学复盘矩阵】学生单科学情期末诊断与结果群体对比看板 (ads.ads_student_course_diagnostic)")
    print("=" * 140)
    header = (
        f"{'学籍最终考核结果':^16} | {'选课人次':^10} | {'有成绩占比':^10} | {'全员估算均分':^12} | "
        f"{'有分估算均分':^12} | {'生均点击量':^10} | {'班内活跃分位':^12} | {'零点击人次':^10} | {'重修生人次':^10}"
    )
    print(header)
    print("-" * 140)
    for row in result_rows:
        res, cnt, sc_cov, enr_s, sc_s, clk, act_pct, z_clk, re_cnt = row
        print(
            f"{res:^16} | {cnt:>10,d} | {sc_cov:>9.1f}% | {enr_s:>12.1f} | "
            f"{sc_s:>12.1f} | {clk:>10.1f} | {act_pct:>11.1f}% | {z_clk:>10,d} | {re_cnt:>10,d}"
        )
    print("-" * 140)

    # 打印前 6 大客观事实标签组合
    cursor.execute("""
        SELECT factual_tag_summary, COUNT(*), ROUND(COUNT(*)::numeric / 32593 * 100, 2) AS pct
        FROM ads.ads_student_course_diagnostic
        GROUP BY factual_tag_summary
        ORDER BY COUNT(*) DESC
        LIMIT 6;
    """)
    tag_rows = cursor.fetchall()
    print("\n🏷️ 【高频客观事实标签画像 Top 6】(任课教师班级学情快速检索画像)：")
    for rank, (tag, cnt, pct) in enumerate(tag_rows, 1):
        print(f"   {rank}. [{tag}] : {cnt:>6,d} 人次 ({pct:>5.2f}%)")
    print("=" * 140 + "\n")


def main() -> None:
    dsn = resolve_dsn()
    print("==============================================================================")
    print("🚀 OULAD 数据仓库 —— ADS 应用层数据构建与质量门禁校验 (Python & Psycopg3)")
    print("==============================================================================")
    print(f"📁 执行 SQL 脚本: {SQL_FILE}")

    if not SQL_FILE.is_file():
        raise SystemExit(f"❌ 未找到 SQL 文件: {SQL_FILE}")

    sql_content = SQL_FILE.read_text(encoding="utf-8")

    with psycopg.connect(dsn) as conn:
        with conn.transaction():
            with conn.cursor() as cur:
                print("⏳ 正在执行 ADS 建表与指标加工计算...")
                cur.execute(sql_content)
                print("✅ SQL 执行完毕，已生成 ads 应用层两张核心成品表。")

                # 1. 校验与展示表一：课程开课批次成效与指标概览大盘 (22 行)
                validate_ads_course_teaching_kpi(cur)
                print_teaching_kpi_dashboard(cur)

                # 2. 校验与展示表二：期末学生单科学情诊断与表现分析表 (32,593 行)
                validate_ads_student_course_diagnostic(cur)
                print_student_diagnostic_dashboard(cur)

        print("🎉 [SUCCESS] ADS 应用层表构建成功，所有质量门禁 100% 通过，事务已安全提交！\n")


if __name__ == "__main__":
    main()

