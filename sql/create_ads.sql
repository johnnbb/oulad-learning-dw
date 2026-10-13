-- ==============================================================================
-- OULAD 学习分析数仓 —— ADS 应用数据层构建脚本 (create_ads.sql)
-- 
-- 架构定位：
--   ADS (Application Data Service) 是面向特定终端与业务决策场景的成品层。
--   本脚本构建第一张核心概览表：
--   ads.ads_course_teaching_kpi (课程开课批次成效与指标概览大盘)
-- 
-- 口径修正与设计原则：
--   1. 显式区分成绩覆盖度：新增 scored_student_count 与 score_coverage_rate，拒绝无成绩按 0 分盲目定性。
--   2. 区分退课与考核成效：并列展示 enrolled_pass_rate (以全体选课为分母) 与 completion_pass_rate (已结课通过率)。
--   3. 严谨用词：改用 withdrawn_rate (退课率)；改用 avg_passer_score (通过者均分)，消除过度解释与伪去幸存者偏差。
--   4. 结果预警分级：定位为客观结果筛查标签 (course_result_alert_tier)，不做教师水平主观定性。
-- ==============================================================================

CREATE SCHEMA IF NOT EXISTS ads;

-- ==============================================================================
-- 表一：课程开课批次成效与指标概览大盘 (ads.ads_course_teaching_kpi)
-- 粒度：一次课程开设班次 (course_key PRIMARY KEY)，全校共 22 行
-- ==============================================================================
DROP TABLE IF EXISTS ads.ads_course_teaching_kpi CASCADE;

CREATE TABLE ads.ads_course_teaching_kpi (
    -- 1. 维度代理主键与开课元数据
    course_key                      INTEGER PRIMARY KEY,
    code_module                     VARCHAR(10) NOT NULL,
    code_presentation               VARCHAR(10) NOT NULL,
    academic_year                   INTEGER NOT NULL,
    cohort_season                   VARCHAR(10) NOT NULL,
    presentation_length             INTEGER,

    -- 2. 办学规模与学籍状态绝对人数 (底数度量)
    total_enrolled_students         INTEGER NOT NULL,
    scored_student_count            INTEGER NOT NULL,  -- 本班次有成绩考核记录的学生数
    total_passed_students           INTEGER NOT NULL,  -- 考核通过总人数 (Pass + Distinction)
    distinction_students            INTEGER NOT NULL,  -- 考核优秀总人数 (Distinction)
    total_withdrawn_students        INTEGER NOT NULL,  -- 中途退课总人数 (Withdrawn)
    total_failed_students           INTEGER NOT NULL,  -- 课程未通过总人数 (Fail)

    -- 3. 考核覆盖率与双口径通过率 (百分制，0.00 ~ 100.00)
    score_coverage_rate             NUMERIC(5, 2) NOT NULL,  -- 至少单项有分覆盖率: scored ÷ enrolled × 100%
    enrolled_pass_rate              NUMERIC(5, 2) NOT NULL,  -- 全员选课通过率: passed ÷ enrolled × 100%
    completion_pass_rate            NUMERIC(5, 2),           -- 已结课学生通过率: passed ÷ (passed + failed) × 100%
    distinction_rate                NUMERIC(5, 2) NOT NULL,  -- 优秀率: distinction ÷ enrolled × 100%
    withdrawn_rate                  NUMERIC(5, 2) NOT NULL,  -- 单科退课率: withdrawn ÷ enrolled × 100%
    fail_rate                       NUMERIC(5, 2) NOT NULL,  -- 课程未通过率: failed ÷ enrolled × 100%

    -- 4. 学术得分三阶标尺 (客观梯度呈现，均为数仓规则估算分，非校方官方成绩单总分)
    avg_enrolled_score              NUMERIC(5, 2),  -- 注册全员规则估算均分 (无已评分考核按 0 折算)
    avg_scored_student_score        NUMERIC(5, 2),  -- 至少单项有分学生估算均分 (排除 6,773 条无评分记录选课，含部分缺分低估)
    avg_passer_score                NUMERIC(5, 2),  -- 有成绩通过学生估算均分 (要求 scored_assessment_count > 0，排除 3 条无评分通过者)

    -- 5. 数字化学习交互行为结构 (辅助分析，不作定性证明)
    total_vle_clicks                INTEGER NOT NULL,
    avg_clicks_per_student          NUMERIC(10, 1) NOT NULL,
    content_click_pct               NUMERIC(5, 2) NOT NULL,  -- 课件资源点击占比 (oucontent)
    forum_click_pct                 NUMERIC(5, 2) NOT NULL,  -- 论坛社群点击占比 (forumng)
    quiz_click_pct                  NUMERIC(5, 2) NOT NULL,  -- 测验刷题点击占比 (quiz/externalquiz)

    -- 6. 结果预警分级与异常指标识别 (纯客观结果筛选)
    enrolled_pass_rate_rank         INTEGER NOT NULL,  -- 选课通过率全校排位 (1 至 22)
    withdrawn_rate_rank             INTEGER NOT NULL,  -- 退课率高低排位 (1 为退课率最高)
    course_result_alert_tier        VARCHAR(20) NOT NULL,  -- 标杆成效班次 / 常规平稳班次 / 重点预警班次
    primary_alert_indicator         VARCHAR(30) NOT NULL,  -- 退课率偏高 / 结课未通过率偏高 / 指标平稳

    -- 7. 数仓 ETL 元数据
    etl_loaded_at                   TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE ads.ads_course_teaching_kpi IS '课程开课批次成效与指标概览大盘（粒度：一次课程开设，共 22 行）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.course_key IS '课程代理主键（PK，严格对应 dim_course，22 行）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.code_module IS '课程代码（AAA ~ GGG）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.code_presentation IS '学期代码（如 2013J, 2014B）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.academic_year IS '开课所属学年（2013 / 2014）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.cohort_season IS '开课学期季节（Spring / Autumn）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.presentation_length IS '计划开课周期天数';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.total_enrolled_students IS '全班总选课注册人数（基础规模分母）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.scored_student_count IS '至少完成一项已评分考核的学生数（非单科完整成绩覆盖人数）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.total_passed_students IS '考核通过总人数（含 Pass 与 Distinction）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.distinction_students IS '考核优秀总人数（Distinction）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.total_withdrawn_students IS '中途退课总人数（Withdrawn）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.total_failed_students IS '课程考核未通过总人数（Fail）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.score_coverage_rate IS '至少单项考核有分的覆盖率（scored_student_count ÷ total_enrolled × 100%）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.enrolled_pass_rate IS '全员选课通过率（passed ÷ total_enrolled × 100%）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.completion_pass_rate IS '已结课学生通过率（passed ÷ (passed + failed) × 100%，剥离退课干扰）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.distinction_rate IS '优秀率（distinction ÷ total_enrolled × 100%）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.withdrawn_rate IS '单科退课率（withdrawn ÷ total_enrolled × 100%）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.fail_rate IS '课程考核未通过率（failed ÷ total_enrolled × 100%）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.avg_enrolled_score IS '注册全员规则估算均分（含无已评分考核折算 0 分，非官方课程成绩）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.avg_scored_student_score IS '至少单项有分学生估算均分（排除 6,773 条无评分选课，含部分缺分保守低估，非成绩齐全学生均分，非官方课程成绩）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.avg_passer_score IS '有成绩通过者规则估算均分（要求 scored_assessment_count > 0，排除 3 条无评分通过者）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.total_vle_clicks IS '全班在线平台总点击交互量';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.avg_clicks_per_student IS '生均在线点击量（数字化交互依赖度）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.content_click_pct IS '教材课件点击结构占比（oucontent）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.forum_click_pct IS '论坛社群点击结构占比（forumng）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.quiz_click_pct IS '在线测验点击结构占比（quiz）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.enrolled_pass_rate_rank IS '全员选课通过率全校排位（1 至 22）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.withdrawn_rate_rank IS '单科退课率高低排位（1 至 22，1 为退课率最高）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.course_result_alert_tier IS '课程成效预警等级（标杆成效班次 / 常规平稳班次 / 重点预警班次）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.primary_alert_indicator IS '主要异常指标识别（退课率偏高 / 结课未通过率偏高 / 指标平稳）';
COMMENT ON COLUMN ads.ads_course_teaching_kpi.etl_loaded_at IS '数仓 ETL 加工时间戳';

-- ==============================================================================
-- 数据装载：自 DWS 汇总宽表向上聚合与指标标准化加工
-- ==============================================================================
INSERT INTO ads.ads_course_teaching_kpi (
    course_key,
    code_module,
    code_presentation,
    academic_year,
    cohort_season,
    presentation_length,
    total_enrolled_students,
    scored_student_count,
    total_passed_students,
    distinction_students,
    total_withdrawn_students,
    total_failed_students,
    score_coverage_rate,
    enrolled_pass_rate,
    completion_pass_rate,
    distinction_rate,
    withdrawn_rate,
    fail_rate,
    avg_enrolled_score,
    avg_scored_student_score,
    avg_passer_score,
    total_vle_clicks,
    avg_clicks_per_student,
    content_click_pct,
    forum_click_pct,
    quiz_click_pct,
    enrolled_pass_rate_rank,
    withdrawn_rate_rank,
    course_result_alert_tier,
    primary_alert_indicator,
    etl_loaded_at
)
WITH cte_student_academic AS (
    -- 从学生单科汇总表中提取优秀人数与通过群体的规则估算均分
    SELECT
        course_key,
        COUNT(CASE WHEN final_result = 'Distinction' THEN 1 END) AS distinction_students,
        ROUND(AVG(CASE WHEN final_result IN ('Pass', 'Distinction') THEN estimated_course_score END), 2) AS avg_passer_score
    FROM dws.student_course_summary
    GROUP BY course_key
),
cte_base_metrics AS (
    SELECT
        cps.course_key,
        cps.code_module,
        cps.code_presentation,
        CAST(SUBSTRING(cps.code_presentation FROM 1 FOR 4) AS INTEGER) AS academic_year,
        CASE 
            WHEN cps.code_presentation LIKE '%B' THEN 'Spring'
            WHEN cps.code_presentation LIKE '%J' THEN 'Autumn'
            ELSE 'Other'
        END AS cohort_season,
        cps.module_presentation_length AS presentation_length,
        cps.total_enrolled_students,
        cps.scored_student_count,
        cps.total_passed_students,
        COALESCE(sa.distinction_students, 0) AS distinction_students,
        cps.total_withdrawn_students,
        cps.total_failed_students,
        -- 比率指标
        ROUND(cps.scored_student_count::numeric / NULLIF(cps.total_enrolled_students, 0) * 100, 2) AS score_coverage_rate,
        ROUND(cps.total_passed_students::numeric / NULLIF(cps.total_enrolled_students, 0) * 100, 2) AS enrolled_pass_rate,
        ROUND(cps.total_passed_students::numeric / NULLIF(cps.total_passed_students + cps.total_failed_students, 0) * 100, 2) AS completion_pass_rate,
        ROUND(COALESCE(sa.distinction_students, 0)::numeric / NULLIF(cps.total_enrolled_students, 0) * 100, 2) AS distinction_rate,
        ROUND(cps.total_withdrawn_students::numeric / NULLIF(cps.total_enrolled_students, 0) * 100, 2) AS withdrawn_rate,
        ROUND(cps.total_failed_students::numeric / NULLIF(cps.total_enrolled_students, 0) * 100, 2) AS fail_rate,
        -- 规则估算均分 (来自 DWS 开课班次汇总表，口径统一)
        cps.avg_enrolled_estimated_score AS avg_enrolled_score,
        cps.avg_scored_estimated_score AS avg_scored_student_score,
        sa.avg_passer_score,
        -- 交互结构
        cps.total_vle_clicks,
        ROUND(cps.total_vle_clicks::numeric / NULLIF(cps.total_enrolled_students, 0), 1) AS avg_clicks_per_student,
        ROUND(cps.content_clicks::numeric / NULLIF(cps.total_vle_clicks, 0) * 100, 2) AS content_click_pct,
        ROUND(cps.forum_clicks::numeric / NULLIF(cps.total_vle_clicks, 0) * 100, 2) AS forum_click_pct,
        ROUND(cps.quiz_clicks::numeric / NULLIF(cps.total_vle_clicks, 0) * 100, 2) AS quiz_click_pct
    FROM dws.course_presentation_summary cps
    LEFT JOIN cte_student_academic sa ON cps.course_key = sa.course_key
)
SELECT
    course_key,
    code_module,
    code_presentation,
    academic_year,
    cohort_season,
    presentation_length,
    total_enrolled_students,
    scored_student_count,
    total_passed_students,
    distinction_students,
    total_withdrawn_students,
    total_failed_students,
    score_coverage_rate,
    enrolled_pass_rate,
    completion_pass_rate,
    distinction_rate,
    withdrawn_rate,
    fail_rate,
    avg_enrolled_score,
    avg_scored_student_score,
    avg_passer_score,
    total_vle_clicks,
    avg_clicks_per_student,
    content_click_pct,
    forum_click_pct,
    quiz_click_pct,
    -- 排位
    RANK() OVER (ORDER BY enrolled_pass_rate DESC, total_passed_students DESC) AS enrolled_pass_rate_rank,
    RANK() OVER (ORDER BY withdrawn_rate DESC, total_withdrawn_students DESC) AS withdrawn_rate_rank,
    -- 结果预警分级 (客观阈值筛选)
    CASE 
        WHEN enrolled_pass_rate >= 55.00 AND withdrawn_rate <= 25.00 AND fail_rate <= 25.00 THEN '标杆成效班次'
        WHEN enrolled_pass_rate < 40.00 OR withdrawn_rate >= 35.00 OR fail_rate >= 28.00 THEN '重点预警班次'
        ELSE '常规平稳班次'
    END AS course_result_alert_tier,
    -- 主要异常指标项识别 (客观指标特征，不做根因主观判定)
    CASE 
        WHEN withdrawn_rate >= 35.00 THEN '退课率偏高'
        WHEN completion_pass_rate < 60.00 THEN '结课未通过率偏高'
        WHEN fail_rate >= 28.00 THEN '全员未通过率偏高'
        ELSE '指标平稳'
    END AS primary_alert_indicator,
    CURRENT_TIMESTAMP AS etl_loaded_at
FROM cte_base_metrics
ORDER BY enrolled_pass_rate DESC;


-- ==============================================================================
-- 表二：期末学生单科学情诊断与表现分析表 (ads.ads_student_course_diagnostic)
-- 粒度：学生 x 课程开设班次 (student_key, course_key 联合主键)，全校共 32,593 行
-- 业务定位：
--   面向任课教师与教研室的结课后微观学情诊断工作台。
--   回答“谁退课、谁未通过、表现如何、在班级处于什么相对分位段、具备哪些可核查的事实标签”，
--   彻底规避学期中未来信息穿越，支撑教学复盘、试卷与作业难度评估以及差异化帮扶复盘。
-- ==============================================================================
DROP TABLE IF EXISTS ads.ads_student_course_diagnostic CASCADE;

CREATE TABLE ads.ads_student_course_diagnostic (
    -- 1. 联合代理主键与开课维度
    student_key                     INTEGER NOT NULL,
    course_key                      INTEGER NOT NULL,
    id_student                      VARCHAR(20) NOT NULL,
    code_module                     VARCHAR(10) NOT NULL,
    code_presentation               VARCHAR(10) NOT NULL,

    -- 2. 学籍背景与修读历史 (客观事实)
    gender                          VARCHAR(10) NOT NULL,
    region                          VARCHAR(50),
    highest_education               VARCHAR(50),
    imd_band                        VARCHAR(20),
    age_band                        VARCHAR(20) NOT NULL,
    num_of_prev_attempts            INTEGER NOT NULL,  -- 此前修读本门课次数 (0为首修，>=1为重修，非历史挂科门数)
    studied_credits                 INTEGER NOT NULL,  -- 本学期所修总学分
    registration_day_offset         INTEGER,           -- 报名注册相对天数 (负数表示开课前)
    unregistration_day_offset       INTEGER,           -- 退课相对天数 (未退课为 NULL)
    final_result                    VARCHAR(20) NOT NULL,  -- 最终考核结果 (Pass/Distinction/Fail/Withdrawn)

    -- 3. 考核完成度与学术表现
    score_status                    VARCHAR(20) NOT NULL,  -- 按当前课程考纲规则判定的评分状态 (NO_SCORE/PARTIAL_SCORE/COMPLETE_SCORE)
    score_rule_type                 VARCHAR(20) NOT NULL,  -- 规则折算类型 (HYBRID_50_50/CA_WEIGHTED/CA_EQUAL_AVG)
    scored_assessment_count         INTEGER NOT NULL,      -- 获得有效评分的考核项数
    assessment_record_count         INTEGER NOT NULL,      -- 事实表提交记录总数
    ca_weighted_score               NUMERIC(5, 2) NOT NULL,  -- 平时考核加权分 (0.00 ~ 100.00)
    exam_score                      NUMERIC(5, 2),         -- 期末考卷面分 (仅CCC/DDD，其余为 NULL)
    estimated_course_score          NUMERIC(5, 2),         -- 规则估算总分 (无评分记录为 NULL，非官方成绩单)
    banked_assessment_count         INTEGER NOT NULL,      -- 免修继承考核项数
    late_assessment_count           INTEGER NOT NULL,      -- 平时考核迟交次数

    -- 4. 数字化学习平台交互全貌
    total_vle_clicks                INTEGER NOT NULL,      -- 在线平台总点击交互量
    active_vle_days                 INTEGER NOT NULL,      -- 实际在线交互活跃天数
    visited_vle_resources           INTEGER NOT NULL,      -- 访问过的不同资源种类数

    -- 5. 班级内部相对百分位 (同班次内对齐，0.00 ~ 100.00%)
    class_activity_percentile       NUMERIC(5, 2) NOT NULL,  -- 平台总点击量在全班中的百分位
    class_score_percentile          NUMERIC(5, 2),           -- 估算分在全班有分群体中的百分位 (无分选课为 NULL)

    -- 6. 可核查的客观事实标签体系 (纯可验证事实，拒绝主观定性)
    is_zero_click                   BOOLEAN NOT NULL,  -- 全学期 0 点击 (total_vle_clicks = 0)
    is_unrated_enrollment           BOOLEAN NOT NULL,  -- 全学期无评分 (score_status = 'NO_SCORE')
    is_frequent_late                BOOLEAN NOT NULL,  -- 多次迟交 (late_assessment_count >= 2)
    is_re_registered                BOOLEAN NOT NULL,  -- 本门课程重修生 (num_of_prev_attempts > 0)
    is_pre_course_withdrawn         BOOLEAN NOT NULL,  -- 开课前退课 (final_result = 'Withdrawn' 且退课天数 < 0)
    is_early_withdrawn              BOOLEAN NOT NULL,  -- 开课初期退课 (final_result = 'Withdrawn' 且退课天数介于 0 至 30)
    is_high_activity_learner        BOOLEAN NOT NULL,  -- 平台活跃度处于班级前 20%
    is_low_activity_learner         BOOLEAN NOT NULL,  -- 平台活跃度处于班级后 20%
    factual_tag_summary             VARCHAR(100) NOT NULL,  -- 客观事实标签组合摘要

    -- 7. 数仓 ETL 元数据
    etl_loaded_at                   TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (student_key, course_key)
);

COMMENT ON TABLE ads.ads_student_course_diagnostic IS '期末学生单科学情诊断与表现分析表（粒度：学生 x 课程开设，共 32,593 行）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.student_key IS '学生代理键（PK，关联 dim_student）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.course_key IS '课程代理键（PK，关联 dim_course）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.id_student IS '学生业务自然学号';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.code_module IS '课程代码（AAA ~ GGG）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.code_presentation IS '学期代码（如 2013J）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.num_of_prev_attempts IS '此前修读本门课程的次数（0为首修，>=1为重修，非历史挂科门数）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.studied_credits IS '本学期所修总学分';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.registration_day_offset IS '报名注册相对天数（负数表示开课前注册）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.unregistration_day_offset IS '退课相对天数（未退课为 NULL）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.final_result IS '期末官方学籍考核结果（Pass/Distinction/Fail/Withdrawn）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.score_status IS '按当前课程考纲规则判定的评分状态（NO_SCORE/PARTIAL_SCORE/COMPLETE_SCORE；注：官方最终结果以 final_result 为准，真实评分覆盖程度请参考 scored_assessment_count）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.score_rule_type IS '数仓估算规则类型（HYBRID_50_50/CA_WEIGHTED/CA_EQUAL_AVG）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.ca_weighted_score IS '平时考核加权总分（上限 100 分）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.exam_score IS '期末考试卷面成绩（仅 CCC/DDD，其余为 NULL）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.estimated_course_score IS '数仓规则估算学业总分（无评分记录为 NULL，非官方成绩单）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.late_assessment_count IS '平时考核迟交次数';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.total_vle_clicks IS '全学期在在线平台的总点击量';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.active_vle_days IS '实际上线交互活跃天数';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.class_activity_percentile IS '本班平台点击量百分位（同班次内对齐，0.00% ~ 100.00%）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.class_score_percentile IS '本班估算分百分位（仅在同班有成绩学生中对齐，无分学生为 NULL）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.is_zero_click IS '全周期零点击标记（total_vle_clicks = 0）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.is_unrated_enrollment IS '全周期无评分标记（score_status = NO_SCORE）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.is_frequent_late IS '多次迟交标记（迟交次数 >= 2）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.is_re_registered IS '重修生标记（此前修读过本门课程）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.is_pre_course_withdrawn IS '开课前退课标记（final_result = Withdrawn 且退课天数 < 0）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.is_early_withdrawn IS '开课初期退课标记（final_result = Withdrawn 且退课天数介于 0 至 30 天）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.is_high_activity_learner IS '高活跃度标记（点击量居本班前 20%）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.is_low_activity_learner IS '低活跃度标记（点击量居本班后 20%）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.factual_tag_summary IS '客观可核查事实标签摘要（管道符拼接，未命中任何特征标签为 NO_SELECTED_TAG）';
COMMENT ON COLUMN ads.ads_student_course_diagnostic.etl_loaded_at IS '数仓 ETL 加工时间戳';

-- 数据装载
INSERT INTO ads.ads_student_course_diagnostic (
    student_key,
    course_key,
    id_student,
    code_module,
    code_presentation,
    gender,
    region,
    highest_education,
    imd_band,
    age_band,
    num_of_prev_attempts,
    studied_credits,
    registration_day_offset,
    unregistration_day_offset,
    final_result,
    score_status,
    score_rule_type,
    scored_assessment_count,
    assessment_record_count,
    ca_weighted_score,
    exam_score,
    estimated_course_score,
    banked_assessment_count,
    late_assessment_count,
    total_vle_clicks,
    active_vle_days,
    visited_vle_resources,
    class_activity_percentile,
    class_score_percentile,
    is_zero_click,
    is_unrated_enrollment,
    is_frequent_late,
    is_re_registered,
    is_pre_course_withdrawn,
    is_early_withdrawn,
    is_high_activity_learner,
    is_low_activity_learner,
    factual_tag_summary,
    etl_loaded_at
)
WITH cte_scored_percentile AS (
    SELECT 
        student_key, 
        course_key,
        ROUND(PERCENT_RANK() OVER (
            PARTITION BY course_key 
            ORDER BY estimated_course_score
        )::numeric * 100, 2) AS class_score_percentile
    FROM dws.student_course_summary
    WHERE estimated_course_score IS NOT NULL
),
cte_enriched AS (
    SELECT 
        dws.student_key,
        dws.course_key,
        dws.id_student,
        dws.code_module,
        dws.code_presentation,
        s.gender,
        s.region,
        s.highest_education,
        s.imd_band,
        e.age_band_for_presentation AS age_band,
        e.num_of_prev_attempts,
        e.studied_credits,
        e.registration_day_offset,
        e.unregistration_day_offset,
        dws.final_result,
        dws.score_status,
        dws.score_rule_type,
        dws.scored_assessment_count,
        dws.assessment_record_count,
        dws.ca_weighted_score,
        dws.exam_score,
        dws.estimated_course_score,
        dws.banked_assessment_count,
        dws.late_assessment_count,
        dws.total_vle_clicks,
        dws.active_vle_days,
        dws.visited_vle_resources,
        ROUND(PERCENT_RANK() OVER (
            PARTITION BY dws.course_key 
            ORDER BY dws.total_vle_clicks
        )::numeric * 100, 2) AS class_activity_percentile,
        sp.class_score_percentile
    FROM dws.student_course_summary dws
    JOIN dim.dim_student s ON dws.student_key = s.student_key
    JOIN dwd.fact_student_enrollment e ON dws.student_key = e.student_key AND dws.course_key = e.course_key
    LEFT JOIN cte_scored_percentile sp ON dws.student_key = sp.student_key AND dws.course_key = sp.course_key
)
SELECT 
    student_key,
    course_key,
    id_student,
    code_module,
    code_presentation,
    gender,
    region,
    highest_education,
    imd_band,
    age_band,
    num_of_prev_attempts,
    studied_credits,
    registration_day_offset,
    unregistration_day_offset,
    final_result,
    score_status,
    score_rule_type,
    scored_assessment_count,
    assessment_record_count,
    ca_weighted_score,
    exam_score,
    estimated_course_score,
    banked_assessment_count,
    late_assessment_count,
    total_vle_clicks,
    active_vle_days,
    visited_vle_resources,
    class_activity_percentile,
    class_score_percentile,
    -- 客观事实标记
    (total_vle_clicks = 0) AS is_zero_click,
    (score_status = 'NO_SCORE') AS is_unrated_enrollment,
    (late_assessment_count >= 2) AS is_frequent_late,
    (num_of_prev_attempts > 0) AS is_re_registered,
    COALESCE(final_result = 'Withdrawn' AND unregistration_day_offset < 0, FALSE) AS is_pre_course_withdrawn,
    COALESCE(final_result = 'Withdrawn' AND unregistration_day_offset BETWEEN 0 AND 30, FALSE) AS is_early_withdrawn,
    (class_activity_percentile >= 80.00) AS is_high_activity_learner,
    (class_activity_percentile <= 20.00) AS is_low_activity_learner,
    COALESCE(NULLIF(ARRAY_TO_STRING(ARRAY[
        CASE WHEN total_vle_clicks = 0 THEN 'ZERO_CLICK' END,
        CASE WHEN score_status = 'NO_SCORE' THEN 'UNRATED' END,
        CASE WHEN late_assessment_count >= 2 THEN 'FREQUENT_LATE' END,
        CASE WHEN num_of_prev_attempts > 0 THEN 'RE_REGISTERED' END,
        CASE WHEN final_result = 'Withdrawn' AND unregistration_day_offset < 0 THEN 'PRE_COURSE_WITHDRAWN' END,
        CASE WHEN final_result = 'Withdrawn' AND unregistration_day_offset BETWEEN 0 AND 30 THEN 'EARLY_WITHDRAWN' END,
        CASE WHEN class_activity_percentile >= 80.00 THEN 'TOP20_ACTIVITY' END,
        CASE WHEN class_activity_percentile <= 20.00 THEN 'BOTTOM20_ACTIVITY' END
    ], ' | '), ''), 'NO_SELECTED_TAG') AS factual_tag_summary,
    CURRENT_TIMESTAMP AS etl_loaded_at
FROM cte_enriched;

