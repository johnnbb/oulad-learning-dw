-- ==============================================================================
-- 服务/轻度汇总层 (DWS) 构建脚本 (Kimball 标准轻度汇总主题宽表)
-- 包含两张核心实体汇总宽表：
--   1) dws.student_course_summary   (粒度: 学生 x 课程开设，32,593 行)
--   2) dws.student_lifetime_summary (粒度: 独立学生全景，28,785 行)
-- ==============================================================================

CREATE SCHEMA IF NOT EXISTS dws;

-- ==============================================================================
-- 1. 表一：学生单科选课综合汇总表 (dws.student_course_summary)
-- 粒度：一名学生 x 一次课程开设 (student_key, course_key)
-- ==============================================================================
DROP TABLE IF EXISTS dws.student_course_summary CASCADE;

CREATE TABLE dws.student_course_summary (
    -- 维度代理键与业务标识（联合主键）
    student_key                INTEGER NOT NULL,
    course_key                 INTEGER NOT NULL,
    id_student                 VARCHAR(32) NOT NULL,
    code_module                VARCHAR(10) NOT NULL,
    code_presentation          VARCHAR(10) NOT NULL,

    -- 选课生命周期与状态（来自 fact_student_enrollment）
    registration_day_offset     INTEGER,
    unregistration_day_offset   INTEGER,
    final_result               VARCHAR(20),

    -- 考核学业表现度量（来自 fact_student_assessment 聚合）
    assessment_record_count    INTEGER NOT NULL DEFAULT 0,
    scored_assessment_count    INTEGER NOT NULL DEFAULT 0,
    ca_weighted_score          NUMERIC(5, 2) NOT NULL DEFAULT 0.00,
    exam_score                 NUMERIC(5, 2),
    course_academic_score      NUMERIC(5, 2) NOT NULL DEFAULT 0.00,
    banked_assessment_count    INTEGER NOT NULL DEFAULT 0,
    late_eligible_count        INTEGER NOT NULL DEFAULT 0,
    late_assessment_count      INTEGER NOT NULL DEFAULT 0,

    -- VLE 交互投入度量（来自 fact_student_vle 聚合）
    total_vle_clicks           INTEGER NOT NULL DEFAULT 0,
    active_vle_days            INTEGER NOT NULL DEFAULT 0,
    visited_vle_resources      INTEGER NOT NULL DEFAULT 0,

    -- 数仓元数据
    etl_loaded_at              TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (student_key, course_key)
);

COMMENT ON TABLE dws.student_course_summary IS '学生单科选课综合汇总表（粒度：一名学生 x 一次课程开设，轻度汇总事实宽表）';
COMMENT ON COLUMN dws.student_course_summary.student_key IS '学生代理主键（联合主键，逻辑关联 dim_student）';
COMMENT ON COLUMN dws.student_course_summary.course_key IS '课程开设代理主键（联合主键，逻辑关联 dim_course）';
COMMENT ON COLUMN dws.student_course_summary.id_student IS '学生自然业务学号（方便业务直读与排查）';
COMMENT ON COLUMN dws.student_course_summary.code_module IS '课程代码（如 AAA）';
COMMENT ON COLUMN dws.student_course_summary.code_presentation IS '学期代码（如 2013J）';
COMMENT ON COLUMN dws.student_course_summary.registration_day_offset IS '注册报名相对天数（负数代表提前报名）';
COMMENT ON COLUMN dws.student_course_summary.unregistration_day_offset IS '退课相对天数（中途退课记录，未退为 NULL）';
COMMENT ON COLUMN dws.student_course_summary.final_result IS '教务最终评定结果（Pass/Distinction/Fail/Withdrawn）';
COMMENT ON COLUMN dws.student_course_summary.assessment_record_count IS '考核记录总数（无考核为 0）';
COMMENT ON COLUMN dws.student_course_summary.scored_assessment_count IS '有得分的考核记录数（真实判分次数）';
COMMENT ON COLUMN dws.student_course_summary.ca_weighted_score IS '平时考核累计加权总分（排除期末考，仅 TMA+CMA，满分 100 分制，反映平时作业学术分）';
COMMENT ON COLUMN dws.student_course_summary.exam_score IS '期末大考卷面得分（仅限 CCC/DDD 参加考试学生，满分 100 分制，无考卷或缺考为 NULL）';
COMMENT ON COLUMN dws.student_course_summary.course_academic_score IS '课程综合学术得分（满分 100 分制，按大纲类型归一化路由：无考课为平时分，有考课为平时与期末各半，GGG 为平时等权均分，专供 GPA 与 ADS 排名）';
COMMENT ON COLUMN dws.student_course_summary.banked_assessment_count IS '沿用免修免考成绩的记录数';
COMMENT ON COLUMN dws.student_course_summary.late_eligible_count IS '可考核迟交的有效基数（排除免修置换与无截止日记录，作为迟交率分母）';
COMMENT ON COLUMN dws.student_course_summary.late_assessment_count IS '迟交逾期的考核次数（作为迟交率分子）';
COMMENT ON COLUMN dws.student_course_summary.total_vle_clicks IS '平台交互总点击数（无点击为 0）';
COMMENT ON COLUMN dws.student_course_summary.active_vle_days IS '实际上线交互活跃天数（至少有 1 次点击的不同天数）';
COMMENT ON COLUMN dws.student_course_summary.visited_vle_resources IS '访问过的不同学习资源去重数（反映学习广度）';
COMMENT ON COLUMN dws.student_course_summary.etl_loaded_at IS '数仓 ETL 加工时间戳';

-- 装载数据 (两步对齐法)
INSERT INTO dws.student_course_summary (
    student_key,
    course_key,
    id_student,
    code_module,
    code_presentation,
    registration_day_offset,
    unregistration_day_offset,
    final_result,
    assessment_record_count,
    scored_assessment_count,
    ca_weighted_score,
    exam_score,
    course_academic_score,
    banked_assessment_count,
    late_eligible_count,
    late_assessment_count,
    total_vle_clicks,
    active_vle_days,
    visited_vle_resources,
    etl_loaded_at
)
WITH cte_assessment AS (
    SELECT
        f.student_key,
        f.course_key,
        COUNT(*) AS assessment_record_count,
        COUNT(f.score) AS scored_assessment_count,
        COALESCE(ROUND(SUM(CASE WHEN a.assessment_type != 'Exam' THEN f.weighted_score ELSE 0 END), 2), 0.00) AS ca_weighted_score,
        MAX(CASE WHEN a.assessment_type = 'Exam' THEN f.score ELSE NULL END) AS exam_score,
        ROUND(AVG(CASE WHEN a.assessment_type != 'Exam' THEN f.score ELSE NULL END), 2) AS ca_avg_score,
        COUNT(CASE WHEN f.is_banked THEN 1 END) AS banked_assessment_count,
        COUNT(f.submission_delay_days) AS late_eligible_count,
        COUNT(CASE WHEN f.submission_delay_days > 0 THEN 1 END) AS late_assessment_count
    FROM dwd.fact_student_assessment f
    JOIN dim.dim_assessment a ON f.assessment_key = a.assessment_key
    GROUP BY f.student_key, f.course_key
),
cte_vle AS (
    SELECT
        student_key,
        course_key,
        COALESCE(SUM(click_count), 0) AS total_vle_clicks,
        COUNT(DISTINCT interaction_day_offset) AS active_vle_days,
        COUNT(DISTINCT vle_key) AS visited_vle_resources
    FROM dwd.fact_student_vle
    GROUP BY student_key, course_key
)
SELECT
    e.student_key,
    e.course_key,
    s.id_student,
    c.code_module,
    c.code_presentation,
    e.registration_day_offset,
    e.unregistration_day_offset,
    e.final_result,
    COALESCE(a.assessment_record_count, 0) AS assessment_record_count,
    COALESCE(a.scored_assessment_count, 0) AS scored_assessment_count,
    COALESCE(a.ca_weighted_score, 0.00) AS ca_weighted_score,
    a.exam_score AS exam_score,
    CASE 
        WHEN c.code_module IN ('CCC', 'DDD') THEN
            ROUND(0.5 * COALESCE(a.ca_weighted_score, 0.00) + 0.5 * COALESCE(a.exam_score, 0.00), 2)
        WHEN c.code_module = 'GGG' THEN
            COALESCE(a.ca_avg_score, 0.00)
        ELSE
            COALESCE(a.ca_weighted_score, 0.00)
    END AS course_academic_score,
    COALESCE(a.banked_assessment_count, 0) AS banked_assessment_count,
    COALESCE(a.late_eligible_count, 0) AS late_eligible_count,
    COALESCE(a.late_assessment_count, 0) AS late_assessment_count,
    COALESCE(v.total_vle_clicks, 0) AS total_vle_clicks,
    COALESCE(v.active_vle_days, 0) AS active_vle_days,
    COALESCE(v.visited_vle_resources, 0) AS visited_vle_resources,
    CURRENT_TIMESTAMP AS etl_loaded_at
FROM dwd.fact_student_enrollment e
INNER JOIN dim.dim_student s ON e.student_key = s.student_key
INNER JOIN dim.dim_course c ON e.course_key = c.course_key
LEFT JOIN cte_assessment a ON e.student_key = a.student_key AND e.course_key = a.course_key
LEFT JOIN cte_vle v ON e.student_key = v.student_key AND e.course_key = v.course_key;


-- ==============================================================================
-- 2. 表二：学生全生命周期综合画像宽表 (dws.student_lifetime_summary)
-- 粒度：一名独立学生占一行 (student_key PRIMARY KEY)，共 28,785 行
-- 职责：
--   1) 汇聚学生大学全生涯选课学籍与毕业成效 (通过门数、挂科门数、综合通过率)
--   2) 科学计算全科平均修课得分 (avg_course_score，大学 GPA 真实水平)
--   3) 跨课程严格去重自然活跃天数与资源覆盖度，杜绝多门课累加虚增
--   4) 退化整合学生基本人口学画像属性，提供开箱即用的 Student 360 画像
-- ==============================================================================
DROP TABLE IF EXISTS dws.student_lifetime_summary CASCADE;

CREATE TABLE dws.student_lifetime_summary (
    -- 维度代理主键与业务标识
    student_key                 INTEGER PRIMARY KEY,
    id_student                  VARCHAR(32) NOT NULL,

    -- 学生人口学基本画像（退化维表属性，形成 Student 360 实体宽表）
    gender                      VARCHAR(10),
    region                      VARCHAR(64),
    highest_education           VARCHAR(64),
    imd_band                    VARCHAR(20),
    has_disability              BOOLEAN,

    -- 大学全生涯选课与学业成效度量
    total_courses_enrolled      INTEGER NOT NULL DEFAULT 0,
    total_courses_passed        INTEGER NOT NULL DEFAULT 0,
    total_courses_withdrawn     INTEGER NOT NULL DEFAULT 0,
    total_courses_failed        INTEGER NOT NULL DEFAULT 0,
    course_pass_rate            NUMERIC(5, 4),  -- 0.0000 - 1.0000
    avg_course_score            NUMERIC(5, 2),  -- 大学全科平均修课得分 (GPA)

    -- 大学全生涯数字学习投入度量（跨课程严格去重）
    lifetime_total_clicks       INTEGER NOT NULL DEFAULT 0,
    lifetime_active_days        INTEGER NOT NULL DEFAULT 0,  -- 跨课程自然天去重
    lifetime_visited_resources  INTEGER NOT NULL DEFAULT 0,  -- 跨课程访问资源去重

    -- 数仓元数据
    etl_loaded_at               TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE dws.student_lifetime_summary IS '学生全生命周期综合画像宽表（粒度：一名独立学生，Student 360 主题宽表）';
COMMENT ON COLUMN dws.student_lifetime_summary.student_key IS '学生代理主键（PK，严格对应 dim_student，28,785 行）';
COMMENT ON COLUMN dws.student_lifetime_summary.id_student IS '学生自然业务学号';
COMMENT ON COLUMN dws.student_lifetime_summary.gender IS '性别（M/F）';
COMMENT ON COLUMN dws.student_lifetime_summary.region IS '所属地理大区';
COMMENT ON COLUMN dws.student_lifetime_summary.highest_education IS '入学前最高学历';
COMMENT ON COLUMN dws.student_lifetime_summary.imd_band IS '经济贫困指数区间';
COMMENT ON COLUMN dws.student_lifetime_summary.has_disability IS '是否有注册残疾声明';
COMMENT ON COLUMN dws.student_lifetime_summary.total_courses_enrolled IS '大学累计选课门数';
COMMENT ON COLUMN dws.student_lifetime_summary.total_courses_passed IS '大学累计考核通过门数（Pass/Distinction）';
COMMENT ON COLUMN dws.student_lifetime_summary.total_courses_withdrawn IS '大学累计中途退课门数（Withdrawn）';
COMMENT ON COLUMN dws.student_lifetime_summary.total_courses_failed IS '大学累计挂科门数（Fail）';
COMMENT ON COLUMN dws.student_lifetime_summary.course_pass_rate IS '大学综合选课通过率（passed / enrolled）';
COMMENT ON COLUMN dws.student_lifetime_summary.avg_course_score IS '大学全科平均修课得分（GPA，跨课程平均分）';
COMMENT ON COLUMN dws.student_lifetime_summary.lifetime_total_clicks IS '大学四年在线交互总点击量';
COMMENT ON COLUMN dws.student_lifetime_summary.lifetime_active_days IS '大学全生涯实际上线活跃天数（跨课程自然天严格去重）';
COMMENT ON COLUMN dws.student_lifetime_summary.lifetime_visited_resources IS '大学全生涯翻阅过的不同资源总数（跨课程去重）';
COMMENT ON COLUMN dws.student_lifetime_summary.etl_loaded_at IS '数仓 ETL 加工时间戳';

-- 装载数据 (基于单科宽表分层上卷 + 底层 VLE 跨课程精准去重)
INSERT INTO dws.student_lifetime_summary (
    student_key,
    id_student,
    gender,
    region,
    highest_education,
    imd_band,
    has_disability,
    total_courses_enrolled,
    total_courses_passed,
    total_courses_withdrawn,
    total_courses_failed,
    course_pass_rate,
    avg_course_score,
    lifetime_total_clicks,
    lifetime_active_days,
    lifetime_visited_resources,
    etl_loaded_at
)
WITH cte_course_summary AS (
    SELECT
        student_key,
        COUNT(*) AS total_courses_enrolled,
        COUNT(CASE WHEN final_result IN ('Pass', 'Distinction') THEN 1 END) AS total_courses_passed,
        COUNT(CASE WHEN final_result = 'Withdrawn' THEN 1 END) AS total_courses_withdrawn,
        COUNT(CASE WHEN final_result = 'Fail' THEN 1 END) AS total_courses_failed,
        ROUND(COUNT(CASE WHEN final_result IN ('Pass', 'Distinction') THEN 1 END)::numeric / COUNT(*), 4) AS course_pass_rate,
        ROUND(AVG(course_academic_score), 2) AS avg_course_score
    FROM dws.student_course_summary
    GROUP BY student_key
),
cte_vle_lifetime AS (
    SELECT
        f.student_key,
        COALESCE(SUM(f.click_count), 0) AS lifetime_total_clicks,
        COUNT(DISTINCT (
            CASE c.code_presentation 
                WHEN '2013B' THEN DATE '2013-02-01'
                WHEN '2013J' THEN DATE '2013-10-01'
                WHEN '2014B' THEN DATE '2014-02-01'
                WHEN '2014J' THEN DATE '2014-10-01'
            END + f.interaction_day_offset
        )) AS lifetime_active_days,
        COUNT(DISTINCT f.vle_key) AS lifetime_visited_resources
    FROM dwd.fact_student_vle f
    JOIN dim.dim_course c ON f.course_key = c.course_key
    GROUP BY f.student_key
)
SELECT
    s.student_key,
    s.id_student,
    s.gender,
    s.region,
    s.highest_education,
    s.imd_band,
    s.has_disability,
    COALESCE(cs.total_courses_enrolled, 0) AS total_courses_enrolled,
    COALESCE(cs.total_courses_passed, 0) AS total_courses_passed,
    COALESCE(cs.total_courses_withdrawn, 0) AS total_courses_withdrawn,
    COALESCE(cs.total_courses_failed, 0) AS total_courses_failed,
    cs.course_pass_rate,
    cs.avg_course_score,
    COALESCE(vl.lifetime_total_clicks, 0) AS lifetime_total_clicks,
    COALESCE(vl.lifetime_active_days, 0) AS lifetime_active_days,
    COALESCE(vl.lifetime_visited_resources, 0) AS lifetime_visited_resources,
    CURRENT_TIMESTAMP AS etl_loaded_at
FROM dim.dim_student s
LEFT JOIN cte_course_summary cs ON s.student_key = cs.student_key
LEFT JOIN cte_vle_lifetime vl ON s.student_key = vl.student_key;


-- ==============================================================================
-- 3. 表三：课程开设班次运营成效汇总表 (dws.course_presentation_summary)
-- 粒度：一次课程开设占一行 (course_key PRIMARY KEY)，共 22 行
-- 职责：
--   1) 汇聚班级总选课人次与及格、退课、挂科绝对人数（纯可加度量，分子分母成对存储）
--   2) 计算全班平均修课得分 (avg_course_score，班级真实学术均分)
--   3) 细分核心课件 (oucontent)、论坛 (forumng)、测验 (quiz) 的点击交互投入度
-- ==============================================================================
DROP TABLE IF EXISTS dws.course_presentation_summary CASCADE;

CREATE TABLE dws.course_presentation_summary (
    -- 维度代理主键与业务标识
    course_key                  INTEGER PRIMARY KEY,
    code_module                 VARCHAR(10) NOT NULL,
    code_presentation           VARCHAR(10) NOT NULL,

    -- 开课基准属性
    module_presentation_length   INTEGER,

    -- 班级学生规模与状态度量（纯可加基础度量，留给上层计算比率）
    total_enrolled_students     INTEGER NOT NULL DEFAULT 0,
    total_passed_students       INTEGER NOT NULL DEFAULT 0,
    total_withdrawn_students    INTEGER NOT NULL DEFAULT 0,
    total_failed_students       INTEGER NOT NULL DEFAULT 0,

    -- 全班学业绩效度量
    avg_course_score            NUMERIC(5, 2),  -- 全班平均修课得分

    -- 全班数字学习投入细分度量
    total_vle_clicks            INTEGER NOT NULL DEFAULT 0,
    content_clicks              INTEGER NOT NULL DEFAULT 0,  -- 核心教材课件阅读量 (oucontent)
    forum_clicks                INTEGER NOT NULL DEFAULT 0,  -- 论坛社群互动量 (forumng)
    quiz_clicks                 INTEGER NOT NULL DEFAULT 0,  -- 在线测验刷题量 (quiz/externalquiz)

    -- 数仓元数据
    etl_loaded_at               TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE dws.course_presentation_summary IS '课程开设班次运营成效汇总表（粒度：一次课程开设，共 22 行）';
COMMENT ON COLUMN dws.course_presentation_summary.course_key IS '课程开设代理主键（PK，严格对应 dim_course，22 行）';
COMMENT ON COLUMN dws.course_presentation_summary.code_module IS '课程代码（如 AAA）';
COMMENT ON COLUMN dws.course_presentation_summary.code_presentation IS '学期代码（如 2013J）';
COMMENT ON COLUMN dws.course_presentation_summary.module_presentation_length IS '计划开课天数（基准时长）';
COMMENT ON COLUMN dws.course_presentation_summary.total_enrolled_students IS '全班总选课人数（及格率/退课率计算分母）';
COMMENT ON COLUMN dws.course_presentation_summary.total_passed_students IS '全班考核及格总人数（及格率计算分子）';
COMMENT ON COLUMN dws.course_presentation_summary.total_withdrawn_students IS '全班中途退学退课总人数（退课率计算分子）';
COMMENT ON COLUMN dws.course_presentation_summary.total_failed_students IS '全班挂科未通过总人数';
COMMENT ON COLUMN dws.course_presentation_summary.avg_course_score IS '全班平均修课得分（班级学术均分）';
COMMENT ON COLUMN dws.course_presentation_summary.total_vle_clicks IS '全班平台交互总点击量';
COMMENT ON COLUMN dws.course_presentation_summary.content_clicks IS '核心课件阅读总点击量（oucontent）';
COMMENT ON COLUMN dws.course_presentation_summary.forum_clicks IS '论坛社群讨论总点击量（forumng）';
COMMENT ON COLUMN dws.course_presentation_summary.quiz_clicks IS '在线测验刷题总点击量（quiz）';
COMMENT ON COLUMN dws.course_presentation_summary.etl_loaded_at IS '数仓 ETL 加工时间戳';

-- 装载数据
INSERT INTO dws.course_presentation_summary (
    course_key,
    code_module,
    code_presentation,
    module_presentation_length,
    total_enrolled_students,
    total_passed_students,
    total_withdrawn_students,
    total_failed_students,
    avg_course_score,
    total_vle_clicks,
    content_clicks,
    forum_clicks,
    quiz_clicks,
    etl_loaded_at
)
WITH cte_enrollment_summary AS (
    SELECT
        course_key,
        COUNT(*) AS total_enrolled_students,
        COUNT(CASE WHEN final_result IN ('Pass', 'Distinction') THEN 1 END) AS total_passed_students,
        COUNT(CASE WHEN final_result = 'Withdrawn' THEN 1 END) AS total_withdrawn_students,
        COUNT(CASE WHEN final_result = 'Fail' THEN 1 END) AS total_failed_students,
        ROUND(AVG(course_academic_score), 2) AS avg_course_score
    FROM dws.student_course_summary
    GROUP BY course_key
),
cte_vle_breakdown AS (
    SELECT
        f.course_key,
        COALESCE(SUM(f.click_count), 0) AS total_vle_clicks,
        COALESCE(SUM(CASE WHEN v.activity_type = 'oucontent' THEN f.click_count ELSE 0 END), 0) AS content_clicks,
        COALESCE(SUM(CASE WHEN v.activity_type = 'forumng' THEN f.click_count ELSE 0 END), 0) AS forum_clicks,
        COALESCE(SUM(CASE WHEN v.activity_type IN ('quiz', 'externalquiz') THEN f.click_count ELSE 0 END), 0) AS quiz_clicks
    FROM dwd.fact_student_vle f
    JOIN dim.dim_vle v ON f.vle_key = v.vle_key
    GROUP BY f.course_key
)
SELECT
    c.course_key,
    c.code_module,
    c.code_presentation,
    c.module_presentation_length,
    COALESCE(es.total_enrolled_students, 0) AS total_enrolled_students,
    COALESCE(es.total_passed_students, 0) AS total_passed_students,
    COALESCE(es.total_withdrawn_students, 0) AS total_withdrawn_students,
    COALESCE(es.total_failed_students, 0) AS total_failed_students,
    es.avg_course_score,
    COALESCE(vb.total_vle_clicks, 0) AS total_vle_clicks,
    COALESCE(vb.content_clicks, 0) AS content_clicks,
    COALESCE(vb.forum_clicks, 0) AS forum_clicks,
    COALESCE(vb.quiz_clicks, 0) AS quiz_clicks,
    CURRENT_TIMESTAMP AS etl_loaded_at
FROM dim.dim_course c
LEFT JOIN cte_enrollment_summary es ON c.course_key = es.course_key
LEFT JOIN cte_vle_breakdown vb ON c.course_key = vb.course_key;
