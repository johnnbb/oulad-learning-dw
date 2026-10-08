-- ==============================================================================
-- 维度层 (DIM) 构建脚本 (Kimball 代理键标准规范)
-- 职责：存储符合 Kimball 维度建模理论的维度表
-- 特点：
--   1) 主键统一采用数仓自建的整型单一代理键 (Surrogate Key, PK)
--   2) 业务自然键 (Natural Key) 保留为唯一属性，用于源系统匹配与多维关联
--   3) 静态全量基线采用确定性开窗排序生成代理键（数仓规范采用逻辑外键解耦）
-- ==============================================================================

CREATE SCHEMA IF NOT EXISTS dim;

-- ------------------------------------------------------------------------------
-- 1. 学生维度表：dim.dim_student
-- 粒度：纯学生个人（id_student），一行代表一位独立学生
-- 数据来源：stg.student_info
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dim.dim_student;

CREATE TABLE dim.dim_student (
    student_key           INTEGER PRIMARY KEY,
    id_student            VARCHAR(32) NOT NULL UNIQUE,
    gender                VARCHAR(10),
    region                VARCHAR(64),
    highest_education     VARCHAR(64),
    imd_band              VARCHAR(20),
    has_disability        BOOLEAN
);

COMMENT ON TABLE dim.dim_student IS '学生维度表（粒度：单个学生，Kimball代理键规范）';
COMMENT ON COLUMN dim.dim_student.student_key IS '学生代理主键（数仓自增整型）';
COMMENT ON COLUMN dim.dim_student.id_student IS '学生自然业务键（源系统学号）';
COMMENT ON COLUMN dim.dim_student.gender IS '性别（M/F）';
COMMENT ON COLUMN dim.dim_student.region IS '所属地理区域';
COMMENT ON COLUMN dim.dim_student.highest_education IS '最高学历水平';
COMMENT ON COLUMN dim.dim_student.imd_band IS '贫困程度指数区间（Index of Multiple Deprivation）';
COMMENT ON COLUMN dim.dim_student.has_disability IS '是否有注册残疾声明（TRUE/FALSE）';

-- 装载数据
INSERT INTO dim.dim_student (
    student_key,
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
),
deduped_student AS (
    SELECT * FROM ranked_student WHERE rn = 1
)
SELECT 
    ROW_NUMBER() OVER (ORDER BY id_student)::integer AS student_key,
    id_student,
    gender,
    region,
    highest_education,
    imd_band,
    has_disability
FROM deduped_student;


-- ------------------------------------------------------------------------------
-- 2. 课程开设维度表：dim.dim_course
-- 粒度：一次课程开设（code_module x code_presentation），共 22 行
-- 数据来源：stg.courses
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dim.dim_course;

CREATE TABLE dim.dim_course (
    course_key                 INTEGER PRIMARY KEY,
    code_module                VARCHAR(10) NOT NULL,
    code_presentation          VARCHAR(10) NOT NULL,
    module_presentation_length INTEGER,
    presentation_year          INTEGER,
    presentation_month         INTEGER,
    
    CONSTRAINT uq_course_presentation UNIQUE (code_module, code_presentation)
);

COMMENT ON TABLE dim.dim_course IS '课程开设维度表（粒度：课程代码 x 开设学期）';
COMMENT ON COLUMN dim.dim_course.course_key IS '课程开设代理主键（数仓自增整型）';
COMMENT ON COLUMN dim.dim_course.code_module IS '课程代号（如 AAA, BBB）';
COMMENT ON COLUMN dim.dim_course.code_presentation IS '学期开设代号（如 2013J, 2014B）';
COMMENT ON COLUMN dim.dim_course.module_presentation_length IS '开课周期总天数';
COMMENT ON COLUMN dim.dim_course.presentation_year IS '开课年份（衍生自 code_presentation 前4位）';
COMMENT ON COLUMN dim.dim_course.presentation_month IS '开课月份（衍生自末位：B=2月, J=10月）';

-- 装载数据
INSERT INTO dim.dim_course (
    course_key,
    code_module,
    code_presentation,
    module_presentation_length,
    presentation_year,
    presentation_month
)
SELECT 
    ROW_NUMBER() OVER (ORDER BY code_module, code_presentation)::integer AS course_key,
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
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dim.dim_assessment;

CREATE TABLE dim.dim_assessment (
    assessment_key       INTEGER PRIMARY KEY,
    id_assessment        VARCHAR(32) NOT NULL UNIQUE,
    code_module          VARCHAR(10) NOT NULL,
    code_presentation    VARCHAR(10) NOT NULL,
    assessment_type      VARCHAR(10),
    date                 INTEGER,
    weight               NUMERIC(5, 2)
);

COMMENT ON TABLE dim.dim_assessment IS '考核维度表（粒度：单项作业或考试定义）';
COMMENT ON COLUMN dim.dim_assessment.assessment_key IS '考核代理主键（数仓自增整型）';
COMMENT ON COLUMN dim.dim_assessment.id_assessment IS '考核自然业务键（源系统ID）';
COMMENT ON COLUMN dim.dim_assessment.code_module IS '所属课程代号';
COMMENT ON COLUMN dim.dim_assessment.code_presentation IS '所属开课学期代号';
COMMENT ON COLUMN dim.dim_assessment.assessment_type IS '考核类型（TMA作业/CMA机考/Exam期末考）';
COMMENT ON COLUMN dim.dim_assessment.date IS '提交截止相对天数（期末考可为 NULL）';
COMMENT ON COLUMN dim.dim_assessment.weight IS '考核权重百分比（0-100）';

-- 装载数据
INSERT INTO dim.dim_assessment (
    assessment_key,
    id_assessment,
    code_module,
    code_presentation,
    assessment_type,
    date,
    weight
)
SELECT 
    ROW_NUMBER() OVER (ORDER BY id_assessment)::integer AS assessment_key,
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
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dim.dim_vle;

CREATE TABLE dim.dim_vle (
    vle_key              INTEGER PRIMARY KEY,
    id_site              VARCHAR(32) NOT NULL UNIQUE,
    code_module          VARCHAR(10) NOT NULL,
    code_presentation    VARCHAR(10) NOT NULL,
    activity_type        VARCHAR(32),
    week_from            INTEGER,
    week_to              INTEGER
);

COMMENT ON TABLE dim.dim_vle IS '学习平台资源维度表（粒度：单个资源或站点定义）';
COMMENT ON COLUMN dim.dim_vle.vle_key IS '平台资源代理主键（数仓自增整型）';
COMMENT ON COLUMN dim.dim_vle.id_site IS '资源自然业务键（源系统ID）';
COMMENT ON COLUMN dim.dim_vle.code_module IS '所属课程代号';
COMMENT ON COLUMN dim.dim_vle.code_presentation IS '所属开课学期代号';
COMMENT ON COLUMN dim.dim_vle.activity_type IS '资源类型（如 forumng, oucontent, resource, url 等）';
COMMENT ON COLUMN dim.dim_vle.week_from IS '建议学习起始周（NULL 表示全学期常驻）';
COMMENT ON COLUMN dim.dim_vle.week_to IS '建议学习截止周（NULL 表示全学期常驻）';

-- 装载数据
INSERT INTO dim.dim_vle (
    vle_key,
    id_site,
    code_module,
    code_presentation,
    activity_type,
    week_from,
    week_to
)
SELECT 
    ROW_NUMBER() OVER (ORDER BY id_site)::integer AS vle_key,
    id_site,
    code_module,
    code_presentation,
    activity_type,
    week_from,
    week_to
FROM stg.vle;
