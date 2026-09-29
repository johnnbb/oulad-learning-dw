# OULAD 学习行为数仓

本项目使用 [Open University Learning Analytics Dataset（OULAD）](https://research.stem.open.ac.uk/ouanalyse/open-dataset-more/) 的七份 CSV，先完成源数据盘点与 PostgreSQL ODS 导入，再建设 DWD、DWS 和可视化。原始文件位于 `data/raw/archive/`，保持原样，不提交 Git。

## 目录

```text
oulad-learning-dw/
├── data/raw/archive/          # 七份原始 CSV，不修改
├── docs/data_dictionary.md   # 表粒度、关联键和已完成的盘点
├── scripts/profile_data.py   # 表头、样例；--full 扫描行数和空白字段
├── scripts/load_ods.py       # 将指定 CSV 原样导入 ODS
├── sql/create_ods.sql        # ODS 七张落地表
├── sql/check_ods.sql         # 导入后检查
├── .env.example              # 数据库连接配置示例
└── requirements.txt
```

## 数据路线

```text
七份原始 CSV → PostgreSQL ods（字段原样、统一以 text 落地）
                     ↓
              行数、键和关联关系检查
                     ↓
        staging 类型转换 → DWD 业务明细 → DWS 汇总 → 看板
```

OULAD 的七份 CSV 原本就是相互关联的表，可以分别导入 ODS。ODS 不删除空白值、不把相对天数改成真实日期，也不提前合并学生或 VLE 记录。`studentVle.csv` 中同一学生、资源、相对日期可以出现多条记录，后续是否汇总由 DWD 的明确粒度决定。

## 第一步：盘点

在项目根目录运行：

```bash
python3 scripts/profile_data.py
python3 scripts/profile_data.py --full
```

第一条只看文件大小、字段和样例；第二条扫描七份文件，统计行数、空白字段，以及六张较小表的候选键重复数。`studentVle.csv` 超过一千万行，完整扫描需要一些时间。已观察的表结构和行数见 `docs/data_dictionary.md`。

## 第二步：ODS 导入

先准备 PostgreSQL 数据库和连接信息；脚本不会自动读取 `.env`。安装依赖、设置环境变量后，按下列顺序导入：

```bash
python3 -m pip install -r requirements.txt
export OULAD_PG_DSN='postgresql://USER:PASSWORD@HOST:PORT/oulad_dw'
python3 scripts/load_ods.py --table courses
python3 scripts/load_ods.py --table assessments
python3 scripts/load_ods.py --table vle
python3 scripts/load_ods.py --table studentInfo
python3 scripts/load_ods.py --table studentRegistration
python3 scripts/load_ods.py --table studentAssessment
python3 scripts/load_ods.py --table studentVle
```

脚本先核对 CSV 表头，再执行 `sql/create_ods.sql` 建表，使用 PostgreSQL `COPY` 导入。若目标表已有记录，脚本会停止，避免重复导入。它不会自动清空或覆盖已有数据。导入完成后用 `sql/check_ods.sql` 核对行数和关键关联，再开始 staging／DWD。

## 建模时要记住

- `code_module + code_presentation` 表示一次课程开设；学生参与该开设的记录再加 `id_student`。
- `assessments.id_assessment` 关联 `studentAssessment.id_assessment`；`vle.id_site` 关联 `studentVle.id_site`。
- 多个 `date` 字段是相对课程开设开始日的天数，负数可以表示开课前活动，并非错误日期。
- ODS 中的原始空字符串、缺失分数、退课日期等先保留；清洗规则写在后续模型中并记录理由。
