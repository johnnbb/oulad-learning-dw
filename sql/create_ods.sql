-- ODS landing tables deliberately keep source fields as text.
-- No source rows are deduplicated or assigned inferred business types here.
CREATE SCHEMA IF NOT EXISTS ods;

CREATE TABLE IF NOT EXISTS ods.courses (
    code_module text,
    code_presentation text,
    module_presentation_length text
);

CREATE TABLE IF NOT EXISTS ods.assessments (
    code_module text,
    code_presentation text,
    id_assessment text,
    assessment_type text,
    date text,
    weight text
);

CREATE TABLE IF NOT EXISTS ods.vle (
    id_site text,
    code_module text,
    code_presentation text,
    activity_type text,
    week_from text,
    week_to text
);

CREATE TABLE IF NOT EXISTS ods.student_info (
    code_module text,
    code_presentation text,
    id_student text,
    gender text,
    region text,
    highest_education text,
    imd_band text,
    age_band text,
    num_of_prev_attempts text,
    studied_credits text,
    disability text,
    final_result text
);

CREATE TABLE IF NOT EXISTS ods.student_registration (
    code_module text,
    code_presentation text,
    id_student text,
    date_registration text,
    date_unregistration text
);

CREATE TABLE IF NOT EXISTS ods.student_assessment (
    id_assessment text,
    id_student text,
    date_submitted text,
    is_banked text,
    score text
);

CREATE TABLE IF NOT EXISTS ods.student_vle (
    code_module text,
    code_presentation text,
    id_student text,
    id_site text,
    date text,
    sum_click text
);

