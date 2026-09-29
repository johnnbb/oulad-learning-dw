-- Run after all seven files have been loaded.
-- Compare row counts with docs/data_dictionary.md.
SELECT 'courses' AS table_name, COUNT(*) AS row_count FROM ods.courses
UNION ALL SELECT 'assessments', COUNT(*) FROM ods.assessments
UNION ALL SELECT 'vle', COUNT(*) FROM ods.vle
UNION ALL SELECT 'student_info', COUNT(*) FROM ods.student_info
UNION ALL SELECT 'student_registration', COUNT(*) FROM ods.student_registration
UNION ALL SELECT 'student_assessment', COUNT(*) FROM ods.student_assessment
UNION ALL SELECT 'student_vle', COUNT(*) FROM ods.student_vle;

-- These links should be inspected before DWD modelling.
SELECT COUNT(*) AS student_assessment_without_assessment
FROM ods.student_assessment AS sa
LEFT JOIN ods.assessments AS a ON a.id_assessment = sa.id_assessment
WHERE a.id_assessment IS NULL;

SELECT COUNT(*) AS student_vle_without_vle_site
FROM ods.student_vle AS sv
LEFT JOIN ods.vle AS v ON v.id_site = sv.id_site
WHERE v.id_site IS NULL;

SELECT COUNT(*) AS student_vle_without_student_info
FROM ods.student_vle AS sv
LEFT JOIN ods.student_info AS si
  ON si.code_module = sv.code_module
 AND si.code_presentation = sv.code_presentation
 AND si.id_student = sv.id_student
WHERE si.id_student IS NULL;

