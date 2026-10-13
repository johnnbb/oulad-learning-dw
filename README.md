# OULAD 学习分析数据仓库 (OULAD Learning Analytics Data Warehouse)

本项目基于英国开放大学国际权威学习分析数据集（[Open University Learning Analytics Dataset, OULAD](https://analyse.kmi.open.ac.uk/open_dataset)，涵盖 3.2 万名学生、7 门课程、22 个开课批次、1,065 万条交互日志），主导落地 **ODS → DIM / DWD → DWS → ADS** 标准 Kimball 维度建模分层数仓架构。

项目端到端攻克了千万级交互日志的高吞吐安全入库、星型模型维度代理键解耦、跨学期多表关联笛卡尔积治理、异构考纲评分归一化、全周期学情诊断与防未来穿越等关键数据工程挑战，并在全链路部署了事务级原子 Pre-commit 刚性数据质量门禁。

---

## 一、 项目技术栈 (Tech Stack)

* **核心存储与计算引擎**：PostgreSQL 16+（Docker 容器化部署 / 物理部署）
* **接入与调度管道**：Python 3.10+、Psycopg 3（协议级流式二进制 `COPY`）
* **数仓建模范式**：Kimball 维度建模理论（星型模型、累积快照事实表、事务事实表）
* **数据治理与质量控制**：事务内 Pre-commit 刚性门禁体系（涵盖行数守恒、主外键唯一性、考纲状态守恒、标签双向一致性等 40+ 项原子断言）
* **业务分析与可视化**：SQL OLAP 复杂聚合、Percentile 分位数计算、ECharts / Metabase 领导大盘与微观复盘工作台对接

---

## 二、 数仓分层全景架构 (Architecture)

```text
 ┌────────────────────────────────────────────────────────────────────────┐
 │                      OULAD 数据仓库分层架构全景图                       │
 └────────────────────────────────────────────────────────────────────────┘

 [外部原始数据源] 7 份 CSV 原始文件 (443 MB, 包含 1,065 万行 studentVle 交互日志)
        │
        ▼  (基于 Python + Psycopg 3 协议级流式 COPY，1MB 分块流式传输，内存 < 20MB)
 ┌────────────────────────────────────────────────────────────────────────┐
 │ 1. ODS (操作数据层 / 7 张原始 Landing 表，流式安全入库与类型转换规范化)    │
 │    courses, assessments, vle, student_info, student_registration,      │
 │    student_assessment, student_vle                                     │
 └────────────────────────────────────────────────────────────────────────┘
        │
        ├──────────────────────────────────┐
        ▼                                  ▼
 ┌──────────────────────────────┐   ┌─────────────────────────────────────┐
 │ 2. DIM (公共维度层 / 4 大核心维度) │   │ 3. DWD (明细事实层 / 3 大事实表)      │
 │    dim_student (28,785 行)   │   │    fact_student_enrollment (32,593) │
 │    dim_course (22 行)        │   │    - 累积快照事实表 (报名/退课生命周期)  │
 │    dim_assessment (206 行)   │   │    fact_student_assessment (173,912)│
 │    dim_vle (6,364 行)        │   │    - 事务事实表 (平时考核与考试交卷流水) │
 │    * Kimball 自增代理键解耦   │   │    fact_student_vle_daily (845万行) │
 │    * 消除物理外键依赖         │   │    - 日粒度聚合事务事实表 (消除219万碎行)│
 └──────────────────────────────┘   └─────────────────────────────────────┘
        │                                  │
        └─────────────────┬────────────────┘
                          ▼  (两步对齐架构消除多对多笛卡尔积，异构考纲多模式归一化)
 ┌────────────────────────────────────────────────────────────────────────┐
 │ 4. DWS (轻度汇总层 / 3 大主题宽表 / 19 项原子质量门禁)                   │
 │    dws_student_course_summary (32,593 行，学生单科全生命周期全貌宽表)    │
 │    dws_student_lifetime_summary (28,785 行，学生跨课程全生命周期宽表)    │
 │    dws_course_presentation_summary (22 行，课程开设运营成效宽表)        │
 └────────────────────────────────────────────────────────────────────────┘
        │
        ▼  (业务指标治理、双口径通过率脱敏、同班百分位、客观事实标签体系)
 ┌────────────────────────────────────────────────────────────────────────┐
 │ 5. ADS (应用数据层 / 2 大核心场景集市 / 15 项原子质量门禁)              │
 │    ads_course_teaching_kpi (22 行，开课成效大盘，面向院系与教务管理层)    │
 │    ads_student_course_diagnostic (32,593 行，期末学情诊断，面向任课教师) │
 └────────────────────────────────────────────────────────────────────────┘
        │
        ▼
 [下游消费] BI 管理看板 (ECharts/Metabase) / 教学督导复盘 / 算法特征工程储备
```

---

## 三、 数仓应用看板效果演示 (ADS Dashboard Showcase)

本项目在最顶层落地了面向管理层驾驶舱与任课教师微观复盘的两大 ADS 核心数据集市，直连自建交互式 Web 分析大屏：

### 1. 宏观开课成效大盘 (Executive Teaching KPI 看板)
> 覆盖 22 门开课批次，并列展现全员选课通过率 (47.20%) 与已结课通过率 (68.57%) 双口径指标，揭示 31.16% 综合退课率对大盘的拉低影响；三阶梯学术估算得分与客观成效预警分级联动。

<p align="center">
  <img src="assets/dashboard_macro_kpi.png" alt="宏观开课成效大盘" width="95%" />
</p>

---

### 2. 微观单科学情诊断工作台 (Student Academic Diagnostic 复盘台)
> 覆盖 32,593 行学生单科学情全貌，构建 `Distinction / Pass / Fail / Withdrawn` 4 大考评群体的行为对照矩阵，精准呈现高频客观事实标签画像，支持同班相对活跃/成绩分位数的微观检索与下钻。

<p align="center">
  <img src="assets/dashboard_student_diagnostic.png" alt="微观单科学情诊断工作台" width="95%" />
</p>

---

## 四、 核心工程亮点与口径治理 (Engineering Highlights)

### 1. 协议级流式安全接入管道 (ODS)
* **内存隔离与极速入库**：针对 1,065 万行的大型交互日志 `studentVle.csv`（单文件 433MB），基于 Python 底层流与 PostgreSQL 原生流式复制二进制协议，设计 1MB 分块流式传输机制。在宿主机内存严格控制在 20MB 以内的前提下，60 秒内完成全量入库。
* **白名单防御与契约校验**：外部输入与 CSV 表头经过严格的白名单校验，杜绝 SQL 注入；入库后完成类型安全转换与空值清洗。

### 2. Kimball 维度建模与范式事实工程 (DIM & DWD)
* **业务域解耦与代理键体系**：拆解学生档案、开课班次、考评大纲、资源元数据四大业务域，统一构建整型自增代理主键（`student_key`, `course_key`, `assessment_key`, `vle_key`），解耦物理依赖为数仓逻辑外键。
* **累积快照事实表**：将选课生命周期抽象为 `fact_student_enrollment`，涵盖注册、在读、退课到结课的全流程，支持里程碑时间戳与状态变迁分析。
* **日粒度收敛与点击量绝对守恒**：在 DWD 层按 `(student_key, course_key, vle_key, date)` 进行日粒度聚合汇总为 845 万行，压减 219 万细碎交互行（节约 20%+ 存储），门禁刚性确保 **39,604,014 次**平台点击量 100% 绝对守恒。

### 3. 两步对齐架构与异构考纲评分归一化 (DWS)
* **两步对齐杜绝笛卡尔积**：针对重修生在多表级联关联时的扇出（Fan-out）隐患，提出“局部独立预聚合至 `student_key x course_key`，再以选课事实为锚点对齐”的两步对齐方案，彻底消除笛卡尔积。
* **异构考纲多模式治理**：
  * **CCC / DDD 模块**：实行“平时考核 50% + 期末统考 50%”混合评分制；
  * **GGG 模块**：平时考核权重为 0，按多次平时作业原始分求算术平均；
  * **其余模块（AAA/BBB/EEE/FFF）**：按大纲设定权重求加权和。
* **评分状态严格分类**：精确划分 `COMPLETE_SCORE`、`PARTIAL_SCORE` 与 `NO_SCORE`，将 6,773 条完全无评分选课的估算分严格置为 `NULL`，杜绝将缺考生粗暴视作 0 分带来的均分失真。
* **日历基准日推算去重活跃天数**：基于学期基准日期进行锚定映射推算，区分“各科活跃天数累加和”与“跨课程去重自然活跃天数”。

### 4. 业务指标治理与防未来穿越 (ADS)
* **双口径通过率分离**：
  * 全员选课通过率（47.20%，分母为全体注册人次，受 31.16% 退课率拉低）；
  * 已结课通过率（68.57%，分母剔除退课干扰，反映完课考生的真实学业成效）。
* **三阶梯估算得分体系**：
  * 阶梯 1：全员注册估算均分（42.61 分，含缺考按 0 分折算）；
  * 阶梯 2：至少单项有分估算均分（53.79 分，排除无评分选课，含部分缺分低估）；
  * 阶梯 3：有成绩通过者估算均分（73.83 分，覆盖真实考核及格群体）。
* **微观诊断与客观事实标签**：
  * 面向教师期末诊断：落地 `ads_student_course_diagnostic`（32,593 行）；
  * 班内相对百分位：平台点击活跃百分位（0.00% ~ 100.00%）与成绩百分位；
  * 可核查事实标签：`is_zero_click`（零点击）、`is_unrated_enrollment`（无评分）、`is_frequent_late`（频迟交）、`is_re_registered`（重修生）、`is_pre_course_withdrawn`（开课前退课，2,676 人）、`is_early_withdrawn`（开课后 30 天内退课，2,443 人，严格剔除 8 条 Fail 异常退课记录）；未命中特征标签采用中性兜底 `NO_SELECTED_TAG`（9,211 人，避免暗示挂科生为正常）。
* **零未来数据穿越原则（Zero Data Leakage）**：
  * 明确表二为期末事后复盘，绝不将全周期点击量和期末考作为学期中预警输入；
  * 学期中早期预警作为架构演进储备，严格锚定开课第 30 天截面快照（Point-in-Time Snapshot），在第 30 天剔除已离校退课生，自变量仅统计前 30 天发生的行为，期末结果仅作为 Label，彻底杜绝数据泄露。

---

## 五、 项目目录拓扑 (Directory Structure)

```text
oulad-learning-dw/
├── data/
│   └── raw/archive/          # 原始 7 份 CSV 数据文件（受 .gitignore 保护，不入库）
├── sql/
│   ├── create_ods.sql        # 1. ODS 操作数据层建表 DDL
│   ├── check_ods.sql         # 1. ODS 数据入库校验脚本
│   ├── create_staging.sql    # 1. 数据清洗暂存转换 SQL
│   ├── create_dim.sql        # 2. DIM 公共维度层建表与代理键装载 DDL/DML
│   ├── create_dwd.sql        # 3. DWD 明细事实层建模与日粒度收敛 SQL
│   ├── create_dws.sql        # 4. DWS 轻度汇总宽表层建模 SQL (3 大实体主题)
│   └── create_ads.sql        # 5. ADS 应用数据层大盘看板与微观诊断表 SQL (2 大核心集市)
├── scripts/
│   ├── profile_data.py       # 源数据表头、样例与全量质量探测工具
│   ├── load_ods.py           # ODS 协议级流式高效安全入库管道 (Python + Psycopg 3)
│   ├── load_stage.py         # 数据清洗转换执行脚本
│   ├── load_dim.py           # DIM 层维度构建与代理键生成脚本
│   ├── load_dwd.py           # DWD 事实工程装载与日粒度收敛脚本
│   ├── load_dws.py           # DWS 轻度汇总宽表装载与 19 重质量门禁脚本
│   └── load_ads.py           # ADS 应用层报表装载、15 重质量门禁与终端加权看板
├── .env.example              # 数据库连接串模版配置 (OULAD_PG_DSN)
├── .gitignore                # 严格工程过滤配置 (隔离原始大型数据与本地文档)
└── requirements.txt          # Python 核心依赖清单 (psycopg>=3.1.0)
```

---

## 六、 数据集获取与快速复现指南 (Quick Start)

### 1. 原始数据集获取
为遵循工业级规范，**原始数据文件绝不提交到 Git 仓库**（`studentVle.csv` 单文件达 433MB，超出 GitHub 100MB 限制）。
请从以下渠道下载 OULAD 数据集，解压后将 7 份 CSV 放入 `data/raw/archive/` 目录：
* **官方下载地址**：[Open University Learning Analytics Dataset (OULAD)](https://analyse.kmi.open.ac.uk/open_dataset)
* **Kaggle 镜像**：[Kaggle: Open University Learning Analytics dataset](https://www.kaggle.com/datasets/anlgrbz/student-demographics-online-education-dataoulad)

### 2. 环境配置
```bash
# 1. 克隆代码仓库
git clone https://github.com/johnnbb/oulad-learning-dw.git
cd oulad-learning-dw

# 2. 安装 Python 核心依赖
pip install -r requirements.txt

# 3. 配置数据库环境变量 (支持物理机或 Docker 部署的 PostgreSQL 16+)
export OULAD_PG_DSN="postgresql://postgres:postgres@localhost:5432/oulad_dw"
```

### 3. 一键端到端装载数仓各层
按标准数仓链路执行 Python 装载脚本，流水线将自动完成建表、数据加工及原子质量门禁核验：

```bash
# Step 1: 原生流式接入 ODS 操作数据层与清洗转换
python3 scripts/load_ods.py --table courses
python3 scripts/load_ods.py --table assessments
python3 scripts/load_ods.py --table vle
python3 scripts/load_ods.py --table studentInfo
python3 scripts/load_ods.py --table studentRegistration
python3 scripts/load_ods.py --table studentAssessment
python3 scripts/load_ods.py --table studentVle
python3 scripts/load_stage.py

# Step 2: 构建 DIM 公共维度层 (4 大维度表，生成代理键)
python3 scripts/load_dim.py

# Step 3: 事实工程与日粒度收敛 DWD 明细层 (3 大事实表，守恒性校验)
python3 scripts/load_dwd.py

# Step 4: 构建 DWS 轻度汇总宽表层 (3 大实体宽表，执行 19 项原子质量门禁)
python3 scripts/load_dws.py

# Step 5: 落地 ADS 应用集市大盘 (2 大成品表，执行 15 项原子门禁并打印终端看板)
python3 scripts/load_ads.py
```

---

## 七、 质量保障与门禁校验矩阵 (Data Quality Gates)

数仓在 `load_dws.py` 与 `load_ads.py` 内部均实现了**事务内 Pre-commit 刚性数据质量门禁**。若任何断言失败，整个事务将立即回滚，确保数仓物理存储不受脏数据污染：

| 校验层级 | 门禁大类 | 检查项与断言内容 | 预期结果 | 实测状态 |
| :--- | :--- | :--- | :--- | :--- |
| **DWS 层** | 粒度行数对齐 | `student_course_summary` 对齐选课基准总行数 | 32,593 行 | PASS (100%) |
| **DWS 层** | 唯一性守恒 | `(student_key, course_key)` 联合主键唯一性 | 重复数为 0 | PASS (100%) |
| **DWS 层** | 交互量守恒 | 宽表累计点击量与 DWD 平台交互事实表总点击量完全对齐 | 39,604,014 次 | PASS (绝对守恒) |
| **DWS 层** | 异构考纲逻辑 | CCC/DDD 模块 `COMPLETE_SCORE` 考纲期末考与平时分达标断言 | 逻辑异常为 0 | PASS (100%) |
| **DWS 层** | 生涯行数对齐 | `student_lifetime_summary` 对齐全校去重学生自然人总数 | 28,785 行 | PASS (100%) |
| **DWS 层** | 活跃天数守恒 | `sum_course_active_days >= anchored_lifetime_active_days` | 逆序违规为 0 | PASS (100%) |
| **ADS 层** | 班次大盘粒度 | `ads_course_teaching_kpi` 覆盖全部开课批次 | 22 门班次 | PASS (100%) |
| **ADS 层** | 学术得分阶梯 | `全员估算均分 (42.61) <= 有分估算均分 (53.79) <= 通过者估算均分 (73.83)` | 22 班次全满足 | PASS (100%) |
| **ADS 层** | 诊断表主键 | `ads_student_course_diagnostic` 联合代理主键唯一性 | 32,593 行无重复 | PASS (100%) |
| **ADS 层** | 学籍终态守恒 | 4 大学籍最终结果（Pass/Distinction/Fail/Withdrawn）分类守恒 | 100% 守恒 | PASS (100%) |
| **ADS 层** | 退课标签边界 | `is_pre_course_withdrawn` (<0天) 与 `is_early_withdrawn` (0~30天) 严格对齐 | 8 条 Fail 异常 0 误判 | PASS (100%) |
| **ADS 层** | 班级分位数 | 平台活跃百分位 [0.00, 100.00] 全覆盖，成绩分位数作用于有分群体 | 越界为 0 | PASS (100%) |
| **ADS 层** | 逻辑外键完整 | 诊断表与维度表关联，检测孤儿键（Orphan Records） | 孤儿数为 0 | PASS (100%) |

---

## 八、 许可证 (License)

本项目代码部分遵循 [MIT License](LICENSE) 开源协议；OULAD 数据集遵循原作者与英国开放大学的开放学术研究许可。
