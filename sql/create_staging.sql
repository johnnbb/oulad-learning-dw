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
