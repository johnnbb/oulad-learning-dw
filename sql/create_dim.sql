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
