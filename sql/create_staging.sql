-- ==============================================================================
-- Staging (STG) 清洗与标准化层
-- 职责：纯清洗与格式规范化，不进行多表关联，不改变数据原有粒度
-- ==============================================================================

CREATE SCHEMA IF NOT EXISTS stg;

-- ------------------------------------------------------------------------------
-- 1. 清洗 student_info ➔ stg.student_info
-- 清洗动作：
--   1) 修复 imd_band 缺失的百分号 ('10-20' -> '10-20%')，空字符串转 NULL
--   2) studied_credits, num_of_prev_attempts 转换为标准 INTEGER
--   3) disability 转换为规范布尔值 has_disability (TRUE/FALSE)
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS stg.student_info;

CREATE TABLE stg.student_info AS
SELECT 
    code_module,
    code_presentation,
    id_student,
    gender,
    region,
    highest_education,
    CASE 
        WHEN imd_band = '10-20' THEN '10-20%'
        ELSE NULLIF(imd_band, '')
    END AS imd_band,
    age_band,
    num_of_prev_attempts::integer AS num_of_prev_attempts,
    studied_credits::integer      AS studied_credits,
    (disability = 'Y')            AS has_disability,
    final_result
FROM ods.student_info;


-- ------------------------------------------------------------------------------
-- 2. 清洗 student_registration ➔ stg.student_registration
-- 清洗动作：
--   1) NULLIF 过滤空字符串，安全转换为 INTEGER 相对天数
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS stg.student_registration;

CREATE TABLE stg.student_registration AS
SELECT 
    code_module,
    code_presentation,
    id_student,
    NULLIF(date_registration, '')::integer   AS date_registration,
    NULLIF(date_unregistration, '')::integer AS date_unregistration
FROM ods.student_registration;


-- ------------------------------------------------------------------------------
-- 3. 清洗 courses ➔ stg.courses
-- 清洗动作：
--   1) NULLIF 过滤空字符串，将开课周期天数转换为标准 INTEGER
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS stg.courses;

CREATE TABLE stg.courses AS
SELECT 
    code_module,
    code_presentation,
    NULLIF(module_presentation_length, '')::integer AS module_presentation_length
FROM ods.courses;


-- ------------------------------------------------------------------------------
-- 4. 清洗 assessments ➔ stg.assessments
-- 清洗动作：
--   1) id_assessment, code_module, code_presentation 保持字符型业务键
--   2) date 过滤空字符串转为 INTEGER 相对截止天数（期末考可能为 NULL）
--   3) weight 转换为 NUMERIC(5, 2)，保留小数精度权重
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS stg.assessments;

CREATE TABLE stg.assessments AS
SELECT 
    id_assessment,
    code_module,
    code_presentation,
    assessment_type,
    NULLIF(date, '')::integer         AS date,
    NULLIF(weight, '')::numeric(5, 2) AS weight
FROM ods.assessments;


-- ------------------------------------------------------------------------------
-- 5. 清洗 student_assessment ➔ stg.student_assessment
-- 清洗动作：
--   1) date_submitted 安全转换为 INTEGER 相对天数
--   2) is_banked ('0'/'1') 转换为规范布尔值 BOOLEAN
--   3) score 过滤空值（173条分数缺失），转换为 NUMERIC(5, 2)
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS stg.student_assessment;

CREATE TABLE stg.student_assessment AS
SELECT 
    id_assessment,
    id_student,
    NULLIF(date_submitted, '')::integer AS date_submitted,
    (is_banked = '1')                   AS is_banked,
    NULLIF(score, '')::numeric(5, 2)    AS score
FROM ods.student_assessment;


-- ------------------------------------------------------------------------------
-- 6. 清洗 vle ➔ stg.vle
-- 清洗动作：
--   1) id_site, code_module, code_presentation, activity_type 保持标准字符型
--   2) week_from, week_to 过滤空字符串，安全转换为 INTEGER 建议学习周
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS stg.vle;

CREATE TABLE stg.vle AS
SELECT 
    id_site,
    code_module,
    code_presentation,
    activity_type,
    NULLIF(week_from, '')::integer AS week_from,
    NULLIF(week_to, '')::integer   AS week_to
FROM ods.vle;


-- ------------------------------------------------------------------------------
-- 7. 清洗 student_vle ➔ stg.student_vle
-- 清洗动作：
--   1) code_module, code_presentation, id_student, id_site 保持标准字符型业务键
--   2) date 转换为 INTEGER 相对交互天数（允许负数，如开课前预习）
--   3) sum_click 转换为 INTEGER 交互点击次数
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS stg.student_vle;

CREATE TABLE stg.student_vle AS
SELECT 
    code_module,
    code_presentation,
    id_student,
    id_site,
    NULLIF(date, '')::integer      AS date,
    NULLIF(sum_click, '')::integer AS sum_click
FROM ods.student_vle;

