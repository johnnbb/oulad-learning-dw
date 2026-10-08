-- ==============================================================================
-- 明细事实层 (DWD) 构建脚本 (Kimball 累积快照事实表规范)
-- 职责：存储基于业务过程构建的明细事实表
-- 特点：
--   1) 外键完全采用 DIM 层的整型代理主键 (Surrogate Key)
--   2) 累积快照事实表覆盖实体全生命周期（报名 ➔ 退课 ➔ 结课）
--   3) 基于代理键联合主键实施 ON CONFLICT DO UPDATE (UPSERT) 原地幂等更新
-- ==============================================================================

CREATE SCHEMA IF NOT EXISTS dwd;

-- ------------------------------------------------------------------------------
-- 1. 学生选课与结课累积快照事实表：dwd.fact_student_enrollment
-- 粒度：一名学生参加一次课程开设（student_key x course_key），共 32,593 行
-- 数据来源：stg.student_info JOIN stg.student_registration
-- 维度关联：dim.dim_student (student_key), dim.dim_course (course_key)
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dwd.fact_student_enrollment;

CREATE TABLE dwd.fact_student_enrollment (
    -- 代理维度键（联合主键，作为逻辑外键关联维表，数仓解耦不建物理外键约束）
    student_key                INTEGER NOT NULL,
    course_key                 INTEGER NOT NULL,
    
    -- 选课当下的即时状态快照（解决跨学期变化）
    age_band_for_presentation  VARCHAR(20),
    num_of_prev_attempts       INTEGER,
    studied_credits            INTEGER,
    
    -- 累积快照生命周期里程碑度量
    registration_day_offset    INTEGER,     -- 报名注册相对天数（可为负数）
    unregistration_day_offset  INTEGER,     -- 退课相对天数（未退课为 NULL）
    final_result               VARCHAR(20), -- 最终考核结果（Pass / Fail / Distinction / Withdrawn）
    
    -- 基础计数度量（固定为 1，便于下游 SUM 统计选课人次）
    enrollment_count           INTEGER NOT NULL DEFAULT 1,
    
    PRIMARY KEY (student_key, course_key)
);

COMMENT ON TABLE dwd.fact_student_enrollment IS '学生选课与结课累积快照事实表（粒度：学生 x 课程开设，生命周期闭环）';
COMMENT ON COLUMN dwd.fact_student_enrollment.student_key IS '学生代理键（逻辑外键关联 dim_student）';
COMMENT ON COLUMN dwd.fact_student_enrollment.course_key IS '课程开设代理键（逻辑外键关联 dim_course）';
COMMENT ON COLUMN dwd.fact_student_enrollment.age_band_for_presentation IS '选课当下的学生年龄段（即时快照）';
COMMENT ON COLUMN dwd.fact_student_enrollment.num_of_prev_attempts IS '此前修读/重修本门课次数';
COMMENT ON COLUMN dwd.fact_student_enrollment.studied_credits IS '本学期所修总学分';
COMMENT ON COLUMN dwd.fact_student_enrollment.registration_day_offset IS '报名注册相对天数（开课前为负数）';
COMMENT ON COLUMN dwd.fact_student_enrollment.unregistration_day_offset IS '退课相对天数（未退课为 NULL）';
COMMENT ON COLUMN dwd.fact_student_enrollment.final_result IS '最终考核结果（Pass/Fail/Distinction/Withdrawn）';
COMMENT ON COLUMN dwd.fact_student_enrollment.enrollment_count IS '选课人次计数度量（固定为 1）';

-- 装载数据与累积快照 UPSERT 维护
INSERT INTO dwd.fact_student_enrollment (
    student_key,
    course_key,
    age_band_for_presentation,
    num_of_prev_attempts,
    studied_credits,
    registration_day_offset,
    unregistration_day_offset,
    final_result,
    enrollment_count
)
SELECT 
    s.student_key,
    c.course_key,
    i.age_band AS age_band_for_presentation,
    i.num_of_prev_attempts,
    i.studied_credits,
    r.date_registration AS registration_day_offset,
    r.date_unregistration AS unregistration_day_offset,
    i.final_result,
    1 AS enrollment_count
FROM stg.student_info i
JOIN stg.student_registration r
    ON i.code_module = r.code_module
   AND i.code_presentation = r.code_presentation
   AND i.id_student = r.id_student
JOIN dim.dim_student s 
    ON i.id_student = s.id_student
JOIN dim.dim_course c 
    ON i.code_module = c.code_module
   AND i.code_presentation = c.code_presentation;

-- 架构说明：
-- 1) 当前离线批处理脚本采用全量幂等覆写（DROP & CREATE + INSERT），单次装载无需触发 ON CONFLICT。
-- 2) 在生产日常增量调度（生命周期推进）场景下，可采用如下原生 UPSERT 语句就地更新：
--    ON CONFLICT (student_key, course_key) DO UPDATE SET 
--        unregistration_day_offset = EXCLUDED.unregistration_day_offset,
--        final_result = EXCLUDED.final_result;


-- ------------------------------------------------------------------------------
-- 2. 学生考核提交事务事实表：dwd.fact_student_assessment
-- 粒度：一名学生对单次考核的一次提交事务（student_key x assessment_key），共 173,912 行
-- 数据来源：stg.student_assessment
-- 维度关联：dim.dim_student (student_key), dim.dim_assessment (assessment_key), dim.dim_course (course_key)
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dwd.fact_student_assessment;

CREATE TABLE dwd.fact_student_assessment (
    -- 代理维度键（逻辑外键关联维表）
    student_key              INTEGER NOT NULL,
    course_key               INTEGER NOT NULL,
    assessment_key           INTEGER NOT NULL,
    
    -- 核心事实与属性度量
    submission_day_offset    INTEGER NOT NULL,  -- 实际提交相对天数
    is_banked                BOOLEAN NOT NULL,  -- 是否为上学期免修免考成绩置换
    score                    NUMERIC(5, 2),     -- 原始得分（0-100，允许缺考为 NULL）
    
    -- 业务衍生分析度量（指标与特征下沉：保留连续数值逾期天数、加权贡献分与及格标记）
    submission_delay_days    INTEGER,           -- 逾期/提前天数（正数为逾期天数，负数为提前天数；Exam 无截止日为 NULL）
    weighted_score           NUMERIC(5, 2),     -- 加权得分贡献值（score * weight / 100）
    is_passed                BOOLEAN,           -- 单项考核是否及格（score >= 40.0）
    
    -- 基础计数度量（固定为 1，便于下游 SUM 统计记录总数）
    assessment_record_count  INTEGER NOT NULL DEFAULT 1,
    
    PRIMARY KEY (student_key, assessment_key)
);

COMMENT ON TABLE dwd.fact_student_assessment IS '学生考核提交明细事实表（粒度：学生 x 考核项，事务型事实表）';
COMMENT ON COLUMN dwd.fact_student_assessment.student_key IS '学生代理键（逻辑外键关联 dim_student）';
COMMENT ON COLUMN dwd.fact_student_assessment.course_key IS '课程开设代理键（星型模型退化引入，逻辑外键关联 dim_course）';
COMMENT ON COLUMN dwd.fact_student_assessment.assessment_key IS '考核代理键（逻辑外键关联 dim_assessment）';
COMMENT ON COLUMN dwd.fact_student_assessment.submission_day_offset IS '实际提交相对天数（相对开课日）';
COMMENT ON COLUMN dwd.fact_student_assessment.is_banked IS '是否为免修免考置换成绩（TRUE/FALSE）';
COMMENT ON COLUMN dwd.fact_student_assessment.score IS '原始得分（0-100，173条缺失为 NULL）';
COMMENT ON COLUMN dwd.fact_student_assessment.submission_delay_days IS '逾期天数（实际提交日 - 截止日，正数为逾期，负数为提前；免修置换或无截止日为 NULL）';
COMMENT ON COLUMN dwd.fact_student_assessment.weighted_score IS '加权得分贡献值（score * weight / 100）';
COMMENT ON COLUMN dwd.fact_student_assessment.is_passed IS '单项考核是否及格（score >= 40.0，得分缺失为 NULL）';
COMMENT ON COLUMN dwd.fact_student_assessment.assessment_record_count IS '考核记录计数度量（固定为 1）';

-- 装载数据
INSERT INTO dwd.fact_student_assessment (
    student_key,
    course_key,
    assessment_key,
    submission_day_offset,
    is_banked,
    score,
    submission_delay_days,
    weighted_score,
    is_passed,
    assessment_record_count
)
SELECT 
    s.student_key,
    c.course_key,
    a.assessment_key,
    sa.date_submitted AS submission_day_offset,
    sa.is_banked,
    sa.score,
    CASE 
        WHEN sa.is_banked THEN NULL
        WHEN a.date IS NOT NULL THEN sa.date_submitted - a.date 
        ELSE NULL 
    END AS submission_delay_days,
    CASE 
        WHEN sa.score IS NOT NULL AND a.weight IS NOT NULL 
        THEN ROUND(sa.score * a.weight / 100.0, 2)
        ELSE NULL 
    END AS weighted_score,
    CASE 
        WHEN sa.score IS NOT NULL THEN (sa.score >= 40.0)
        ELSE NULL 
    END AS is_passed,
    1 AS assessment_record_count
FROM stg.student_assessment sa
JOIN dim.dim_student s 
    ON sa.id_student = s.id_student
JOIN dim.dim_assessment a 
    ON sa.id_assessment = a.id_assessment
JOIN dim.dim_course c 
    ON a.code_module = c.code_module 
   AND a.code_presentation = c.code_presentation;


-- ------------------------------------------------------------------------------
-- 3. 学习平台资源交互明细事实表：dwd.fact_student_vle
-- 粒度：一名学生在一天内对一项平台资源的总交互（One row per Student x Course x Resource x Day）
-- 数据规模：8,459,320 行（自 STG 10,655,280 条会话切片聚合收敛，消除 219 万条碎行）
-- 维度关联：dim.dim_student (student_key), dim.dim_course (course_key), dim.dim_vle (vle_key)
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dwd.fact_student_vle;

CREATE TABLE dwd.fact_student_vle (
    -- 代理维度键（逻辑外键关联维表）
    student_key                 INTEGER NOT NULL,
    course_key                  INTEGER NOT NULL,
    vle_key                     INTEGER NOT NULL,
    
    -- 核心事实与属性度量
    interaction_day_offset      INTEGER NOT NULL,  -- 交互发生相对天数（开课前为负数）
    click_count                 INTEGER NOT NULL,  -- 当日对该资源的总点击交互次数（SUM 聚合收敛）
    
    -- 业务衍生分析标记
    is_pre_course_activity      BOOLEAN NOT NULL,  -- 是否为开课前预习行为（interaction_day_offset < 0）
    
    -- 基础计数度量（固定为 1，便于下游 SUM 统计日交互事件频次）
    interaction_record_count    INTEGER NOT NULL DEFAULT 1,
    
    PRIMARY KEY (student_key, course_key, vle_key, interaction_day_offset)
);

COMMENT ON TABLE dwd.fact_student_vle IS '学习平台资源交互明细事实表（粒度：学生 x 课程 x 资源 x 相对天数，日汇总事务事实表）';
COMMENT ON COLUMN dwd.fact_student_vle.student_key IS '学生代理键（逻辑外键关联 dim_student）';
COMMENT ON COLUMN dwd.fact_student_vle.course_key IS '课程开设代理键（逻辑外键关联 dim_course）';
COMMENT ON COLUMN dwd.fact_student_vle.vle_key IS '平台资源代理键（逻辑外键关联 dim_vle）';
COMMENT ON COLUMN dwd.fact_student_vle.interaction_day_offset IS '交互发生相对天数（相对开课日，负数表示开课前预习）';
COMMENT ON COLUMN dwd.fact_student_vle.click_count IS '当日单项资源总点击交互次数（会话批次聚合收敛）';
COMMENT ON COLUMN dwd.fact_student_vle.is_pre_course_activity IS '是否为开课前自主预习交互（TRUE/FALSE）';
COMMENT ON COLUMN dwd.fact_student_vle.interaction_record_count IS '日交互记录计数度量（固定为 1）';

-- 装载数据（Route B：Kimball 规范日粒度聚合收敛）
INSERT INTO dwd.fact_student_vle (
    student_key,
    course_key,
    vle_key,
    interaction_day_offset,
    click_count,
    is_pre_course_activity,
    interaction_record_count
)
SELECT 
    s.student_key,
    c.course_key,
    v.vle_key,
    sv.date AS interaction_day_offset,
    SUM(sv.sum_click)::integer AS click_count,
    (sv.date < 0) AS is_pre_course_activity,
    1 AS interaction_record_count
FROM stg.student_vle sv
JOIN dim.dim_student s 
    ON sv.id_student = s.id_student
JOIN dim.dim_course c 
    ON sv.code_module = c.code_module 
   AND sv.code_presentation = c.code_presentation
JOIN dim.dim_vle v 
    ON sv.id_site = v.id_site
GROUP BY s.student_key, c.course_key, v.vle_key, sv.date;
