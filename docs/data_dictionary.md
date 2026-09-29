# OULAD 数据盘点

来源：[Open University OULAD 官方字段说明](https://research.stem.open.ac.uk/ouanalyse/open-dataset-more/)。本地原始文件：`data/raw/archive/`。以下行数来自 2026-09-29 的本地 CSV 盘点，不包含表头。

| CSV | 行数 | 一行代表什么 | 候选键／关联 |
| --- | ---: | --- | --- |
| `courses.csv` | 22 | 一次课程开设 | `code_module, code_presentation`；本地无重复 |
| `assessments.csv` | 206 | 一项测评 | `id_assessment`；本地无重复 |
| `vle.csv` | 6,364 | 一项课程平台资源 | `id_site`；本地无重复 |
| `studentInfo.csv` | 32,593 | 学生参加一次课程开设的资料及最终结果 | `code_module, code_presentation, id_student`；本地无重复 |
| `studentRegistration.csv` | 32,593 | 学生参加一次课程开设的注册记录 | 同上；本地无重复 |
| `studentAssessment.csv` | 173,912 | 学生在一项测评中的提交与分数 | `id_assessment, id_student`；本地无重复 |
| `studentVle.csv` | 10,655,280 | 学生与平台资源的一条日交互记录 | 通过课程开设、学生、`id_site` 关联；源数据可出现同组合重复，不设唯一键 |

六张较小表的候选键已通过本地 CSV 扫描检查，重复数均为 0。`studentVle.csv` 的前两条记录即为相同学生、资源和日期的两条点击记录，因此后续如需“学生 × 资源 × 日”粒度，应明确执行 `SUM(sum_click)`，不能在 ODS 去重。

## 字段口径

- `code_presentation` 中的 `B`、`J` 分别对应二月、十月开始的课程开设；年份和月份按官方定义解释。
- `date_registration`、`date_unregistration`、`date_submitted`、`studentVle.date` 和 `assessments.date` 是相对开课第 0 天的偏移量，不是公历日期。负数可以合法出现。
- `studentAssessment.score` 可为空；没有提交时可能根本没有记录。不能把无记录或空白分数直接解释为 0 分。
- `studentRegistration.date_unregistration` 为空通常表示未退课；`vle.week_from/week_to` 也可能为空。ODS 保留这些原始值。

## 本地空白字段统计

完整扫描已完成。`assessments.date` 有 11 个空白；`vle.week_from` 和 `week_to` 各有 5,243 个；`studentInfo.imd_band` 有 1,111 个；`studentRegistration.date_registration` 有 45 个、`date_unregistration` 有 22,521 个；`studentAssessment.score` 有 173 个。其余字段未发现空白。空白与缺失记录的业务含义留待 staging／DWD 明确定义。

## 下一次核对

- [x] 运行 `python3 scripts/profile_data.py --full`，保存七表空白字段统计。
- [ ] 导入后运行 `sql/check_ods.sql`，核对行数与孤儿记录。
- [ ] 在 staging 设计 `NULLIF`、安全类型转换和异常记录处理，再定义 DWD 粒度。
