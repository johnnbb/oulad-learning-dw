-- ==============================================================================
-- 维度层 (DIM) 构建脚本
-- 职责：存储符合维度建模规范的维度表，为下游 DWD/DWS 提供一致性分析上下文
-- ==============================================================================

CREATE SCHEMA IF NOT EXISTS dim;

-- ------------------------------------------------------------------------------
-- 1. 学生维度表：dim.dim_student
-- 粒度：纯学生个人（id_student），一行代表一位独立学生
-- 数据来源：stg.student_info
-- 处理逻辑：
--   1) 仅提取纯静态人口学特征属性
--   2) 针对同一个学生修读多门课程的情况，采用开窗函数 ROW_NUMBER() 
--      按开课学期倒序取最新状态（对齐尚硅谷电商数仓最新状态抽取思路）
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dim.dim_student;

CREATE TABLE dim.dim_student (
    id_student            VARCHAR(32) PRIMARY KEY,
    gender                VARCHAR(10),
    region                VARCHAR(64),
    highest_education     VARCHAR(64),
    imd_band              VARCHAR(20),
    has_disability        BOOLEAN
);

COMMENT ON TABLE dim.dim_student IS '学生维度表（粒度：单个学生，去重提取静态人口学属性）';
COMMENT ON COLUMN dim.dim_student.id_student IS '学生唯一标识（主键）';
COMMENT ON COLUMN dim.dim_student.gender IS '性别（M/F）';
COMMENT ON COLUMN dim.dim_student.region IS '所属地理区域';
COMMENT ON COLUMN dim.dim_student.highest_education IS '最高学历水平';
COMMENT ON COLUMN dim.dim_student.imd_band IS '贫困程度指数区间（Index of Multiple Deprivation）';
COMMENT ON COLUMN dim.dim_student.has_disability IS '是否有注册残疾声明（TRUE/FALSE）';

-- 装载数据
INSERT INTO dim.dim_student (
    id_student,
    gender,
    region,
    highest_education,
    imd_band,
    has_disability
)
WITH ranked_student AS (
    SELECT 
        id_student,
        gender,
        region,
        highest_education,
        imd_band,
        has_disability,
        ROW_NUMBER() OVER (
            PARTITION BY id_student 
            ORDER BY code_presentation DESC, code_module DESC
        ) AS rn
    FROM stg.student_info
)
SELECT 
    id_student,
    gender,
    region,
    highest_education,
    imd_band,
    has_disability
FROM ranked_student
WHERE rn = 1;


-- ------------------------------------------------------------------------------
-- 2. 课程开设维度表：dim.dim_course
-- 粒度：一次课程开设（code_module x code_presentation），共 22 行
-- 数据来源：stg.courses
-- 处理逻辑：
--   1) 衍生开课年份 presentation_year (截取前4位)
--   2) 衍生开课月份 presentation_month (按末位映射：B->2, J->10)
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dim.dim_course;

CREATE TABLE dim.dim_course (
    code_module                VARCHAR(10) NOT NULL,
    code_presentation          VARCHAR(10) NOT NULL,
    module_presentation_length INTEGER,
    presentation_year          INTEGER,
    presentation_month         INTEGER,
    
    PRIMARY KEY (code_module, code_presentation)
);

COMMENT ON TABLE dim.dim_course IS '课程开设维度表（粒度：课程代码 x 开设学期）';
COMMENT ON COLUMN dim.dim_course.code_module IS '课程代号（如 AAA, BBB）';
COMMENT ON COLUMN dim.dim_course.code_presentation IS '学期开设代号（如 2013J, 2014B）';
COMMENT ON COLUMN dim.dim_course.module_presentation_length IS '开课周期总天数';
COMMENT ON COLUMN dim.dim_course.presentation_year IS '开课年份（衍生自 code_presentation 前4位）';
COMMENT ON COLUMN dim.dim_course.presentation_month IS '开课月份（衍生自末位：B=2月, J=10月）';

-- 装载数据
INSERT INTO dim.dim_course (
    code_module,
    code_presentation,
    module_presentation_length,
    presentation_year,
    presentation_month
)
SELECT 
    code_module,
    code_presentation,
    module_presentation_length,
    LEFT(code_presentation, 4)::integer AS presentation_year,
    CASE 
        WHEN RIGHT(code_presentation, 1) = 'B' THEN 2
        WHEN RIGHT(code_presentation, 1) = 'J' THEN 10
        ELSE NULL
    END AS presentation_month
FROM stg.courses;


-- ------------------------------------------------------------------------------
-- 3. 考核维度表：dim.dim_assessment
-- 粒度：单项作业或考试定义（id_assessment），共 206 行
-- 数据来源：stg.assessments
-- 处理逻辑：
--   1) 保留考核固有属性（类型、截止天数、权重）
--   2) 遵循精简正交规范，通过 code_module, code_presentation 关联 dim_course，
--      不冗余存储开课年份与月份
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dim.dim_assessment;

CREATE TABLE dim.dim_assessment (
    id_assessment        VARCHAR(32) PRIMARY KEY,
    code_module          VARCHAR(10) NOT NULL,
    code_presentation    VARCHAR(10) NOT NULL,
    assessment_type      VARCHAR(10),
    date                 INTEGER,
    weight               NUMERIC(5, 2)
);

COMMENT ON TABLE dim.dim_assessment IS '考核维度表（粒度：单项作业或考试定义）';
COMMENT ON COLUMN dim.dim_assessment.id_assessment IS '考核唯一标识（主键）';
COMMENT ON COLUMN dim.dim_assessment.code_module IS '所属课程代号';
COMMENT ON COLUMN dim.dim_assessment.code_presentation IS '所属开课学期代号';
COMMENT ON COLUMN dim.dim_assessment.assessment_type IS '考核类型（TMA作业/CMA机考/Exam期末考）';
COMMENT ON COLUMN dim.dim_assessment.date IS '提交截止相对天数（期末考可为 NULL）';
COMMENT ON COLUMN dim.dim_assessment.weight IS '考核权重百分比（0-100）';

-- 装载数据
INSERT INTO dim.dim_assessment (
    id_assessment,
    code_module,
    code_presentation,
    assessment_type,
    date,
    weight
)
SELECT 
    id_assessment,
    code_module,
    code_presentation,
    assessment_type,
    date,
    weight
FROM stg.assessments;


-- ------------------------------------------------------------------------------
-- 4. 学习平台资源维度表：dim.dim_vle
-- 粒度：单项平台资源或站点（id_site），共 6,364 行
-- 数据来源：stg.vle
-- 处理逻辑：
--   1) id_site 声明为主键
--   2) code_module, code_presentation 关联 dim_course
--   3) 保留资源类型 activity_type 与建议学习周区间 (week_from, week_to)
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dim.dim_vle;

CREATE TABLE dim.dim_vle (
    id_site              VARCHAR(32) PRIMARY KEY,
    code_module          VARCHAR(10) NOT NULL,
    code_presentation    VARCHAR(10) NOT NULL,
    activity_type        VARCHAR(32),
    week_from            INTEGER,
    week_to              INTEGER
);

COMMENT ON TABLE dim.dim_vle IS '学习平台资源维度表（粒度：单个资源或站点定义）';
COMMENT ON COLUMN dim.dim_vle.id_site IS '资源唯一标识（主键）';
COMMENT ON COLUMN dim.dim_vle.code_module IS '所属课程代号';
COMMENT ON COLUMN dim.dim_vle.code_presentation IS '所属开课学期代号';
COMMENT ON COLUMN dim.dim_vle.activity_type IS '资源类型（如 forumng, oucontent, resource, url 等）';
COMMENT ON COLUMN dim.dim_vle.week_from IS '建议学习起始周（NULL 表示全学期常驻）';
COMMENT ON COLUMN dim.dim_vle.week_to IS '建议学习截止周（NULL 表示全学期常驻）';

-- 装载数据
INSERT INTO dim.dim_vle (
    id_site,
    code_module,
    code_presentation,
    activity_type,
    week_from,
    week_to
)
SELECT 
    id_site,
    code_module,
    code_presentation,
    activity_type,
    week_from,
    week_to
FROM stg.vle;

