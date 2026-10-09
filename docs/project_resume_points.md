# OULAD 学习分析数仓项目 —— 简历描述与面试支撑底稿 (v1.0)

> **文档说明**：本文档用于沉淀 OULAD 数仓项目在求职简历中的精炼表达，以及对应的技术深挖底稿。
> * **第一部分**为**简历直投版（严格控制字数与排版，每条约 2-3 行，高信息密度）**；
> * **第二部分**为**核心技术落地细节与面试深挖对照**；
> * 本文档为**活文档（Live Document）**，当前版本（v1.0）聚焦已完成的 ODS/STG、DIM 维度层与 DWD 事实层，后续随 DWS/ADS 建设持续迭代更新。

---

## 一、简历直投精炼版（严格控字排版）

* **高性能安全接入管道（协议级流式与幂等治理）**：
  针对千万级（1065万行）学生行为流水与选课日志，基于 Python 结合 PostgreSQL 原生 `COPY` 流式传输协议设计 1MB 分块流式管道，将常驻内存严控在 20MB 以内并在 60s 内完成入库；在清洗层（STG）设计字段白名单校验、时间语义标准化与幂等性检测，杜绝 SQL 注入与脏数据膨胀。

* **Kimball 维度建模与逻辑外键治理（维度架构设计）**：
  拆解开课班次、考评大纲、学生档案与学习资源四大业务域，构建规范星型模型与整型单一代理主键（Surrogate Key）；解耦底层物理外键强约束与 CASCADE 级联删除，改用数仓标准“逻辑外键”；针对开窗排序导致的“键漂移（Key Drift）”隐患，设计调度层依赖拦截门禁与原子协同重建机制，并给出 SCD2 拉链表与 Data Vault 2.0 哈希代理键演进方案。

* **混合事实表建模与事务级质量拦截门禁（明细事实与质量工程）**：
  将选课流程建模为**累积型快照事实表**，单行闭环覆盖报名注册、中途退课至结课总评全生命周期（沉淀 Postgres 原地 UPSERT 与湖仓 MERGE INTO 更新对比）；将考评与交互行为落地为**事务型事实表**并下沉逾期天数等分析度量；设计事务提交前（Pre-commit Gate）强校验机制，通过业务键去重、双向差集 0 孤儿核验与动态行数强对齐，实现异常自动 ROLLBACK，彻底拦截脏数据。

* **跨事实域轻度汇总宽表与异构考评归一化治理（DWS 服务层设计）**：
  针对选课生命周期、考评大纲与千万级交互流水三大业务域，设计两步对齐打宽架构（Two-step CTE Alignment），秒级收敛为 3.2 万行单科画像宽表、2.8 万行学生全景宽表与 22 行课程运营宽表；深入治理异构考核大纲，建立三元度量分权与动态路由规则，攻克期末考混杂导致 3,949 人分数破百的口径污染，将全员真实学术分严格收敛至 [0, 100] 分制；设计学期物理公历锚点对齐机制，彻底修复相对时间去重吞噬 1,991 名跨学期学生活跃天数的时序缺陷；在装载中内置 19 重 Pre-commit 刚性质量门禁，实现 3960 万次交互点击与选课考评记录的绝对守恒。

* **湖仓演进与分布式特征工程（计算扩展与价值输出）**：
  设计从关系型数仓向湖仓一体（MinIO + Parquet）平滑演进架构。利用 Docker 编排 PySpark 算力，通过滑动时间窗口（Rolling Window）分布式提取学生周活跃度、交互沉迷度与迟交拖延特征，沉淀学生综合宽表，为下游学业挂科与退学预警模型提供高可用特征工程支撑。

---

## 二、已完成核心模块深度对照（面试深挖武器库）

在技术面试中，面试官最容易就简历中的上述亮点进行深度追问。以下为代码落地实现与标准对答支撑：

### 1. 维度层深挖：代理键 vs 自然键、键漂移防线
* **面试官追问**：“你们为什么要用代理键？单独重跑 DIM 表时，如何防止事实表代理键错位（键漂移）？”
* **核心对答点**：
  1. **代理键价值**：多源系统 ID 冲突隔离、解耦业务源表主键变动、整型索引极速 JOIN、原生支持拉链表（SCD2）。在大数据分布式离线数仓（如尚硅谷 Hive 模式）中因全量排序 Shuffle 倾斜而常用自然键；而在关系型/MPP 数仓中，代理键是行业标准。
  2. **键漂移防线**：
     * **调度层拦截**：在 [load_dim.py](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/scripts/load_dim.py) 中内置门禁，检测到下游 DWD 存在数据时默认阻断单独重跑；支持 `--cascade-dwd` 在**同一数据库事务内**原子协同重建 DIM 与 DWD。
     * **架构演进**：增量生产环境中可通过“代理键字典映射表（Mapping Table）”或“Data Vault 2.0 哈希代理键（MD5/HashKey）”固化映射，实现终生零漂移。
* **工程落地点**：
  * [create_dim.sql](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/sql/create_dim.sql)（4 张维表构建）
  * [load_dim.py](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/scripts/load_dim.py)（依赖扫描拦截与 `--cascade-dwd` 协同事务）
  * [dim_student_zipper_extension.md](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/docs/dim_student_zipper_extension.md)（SCD2 演进方案）

---

### 2. 事实层深挖：累积快照事实表更新机制
* **面试官追问**：“选课中途有退课和结课，这种会变动的事实表你们是怎么更新和维护的？”
* **核心对答点**：
  1. **模型定义**：选课是一个跨越数月的生命周期，属于经典的**累积型快照事实表（Accumulating Snapshot Fact Table）**，单行记录 `student_key x course_key`。
  2. **三大引擎更新演进**：
     * **传统 Hive (HDFS)**：只读系统无法原地 UPDATE，采用 `9999-12-31` 未完结动态分区合并覆盖流转；
     * **关系型数仓 (PostgreSQL)**：基于代理键联合主键，采用原生行级索引与事务日志，执行毫秒级原地 `UPSERT (ON CONFLICT DO UPDATE)`；
     * **现代湖仓 (Iceberg/Delta)**：基于 Parquet + ACID 事务元数据层，直接执行标准 `MERGE INTO` 语法（COW / MOR 模式）。
* **工程落地点**：
  * [create_dwd.sql](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/sql/create_dwd.sql)（选课与考核事实表）
  * [dwd_fact_enrollment_accumulating_snapshot_extension.md](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/docs/dwd_fact_enrollment_accumulating_snapshot_extension.md)（累积快照更新机制深度文档）

---

### 3. 数据质量深挖：事务内提交前质量门禁（Pre-commit Gate）
* **面试官追问**：“你们如何保证数仓装载时的数据质量？如果源头两张表关联时漏了数据怎么发现？”
* **核心对答点**：
  1. **拒绝无感报错**：不采用 commit 后再用 Python assert 的伪校验，而是将质量门禁全部放在**同一数据库事务内部**。校验失败立即底层 `connection.rollback()`，数据库不留半条脏数据。
  2. **双向差集核验（Bidirectional Orphan Check）**：
     * 不单单核对 JOIN 后的行数，而是独立检查 `stg.student_info` 和 `stg.student_registration` 的业务键唯一性；
     * 执行双向差集检查：`info` 中存在但 `reg` 缺失（必须为 0），`reg` 中存在但 `info` 缺失（必须为 0）；彻底杜绝因源表双向漏行而产生“假阳性通过”。
  3. **逻辑外键 0 孤儿核验**：事实表每一行外键均与 DIM 表做 LEFT JOIN，断言孤儿引用为 0。
* **工程落地点**：
  * [load_dwd.py](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/scripts/load_dwd.py#L30-L150)（四重双向校验与 0 孤儿拦截）

---

### 4. 海量行为事实治理：Kimball 日粒度收敛与点击量守恒
* **面试官追问**：“针对千万级的平台交互日志，事实表粒度如何设计？遇到埋点会话切片如何治理？”
* **核心对答点**：
  1. **粒度精准收敛（Kimball Route B）**：原始 `stg.student_vle` 存在大量同一天同一学生同一资源的碎片会话记录（10,655,280 行）。我们在 DWD 严格声明粒度为“学生 x 课程 x 资源 x 交互天数”，通过 `SUM(sum_click)` 汇聚收敛为 8,459,320 条标准日事务事实行，消除 219 万条碎行并建立 4 维整型复合主键。
  2. **财务级点击量守恒校验**：在事务提交前执行对账门禁，确保汇聚前后总点击量严格锁定在 39,605,099 次（0 丢失、0 膨胀）。
  3. **预习特征下沉**：计算下沉 `is_pre_course_activity`（开课前预习标记，`date < 0`），为下游学业画像提供高价值自律性特征。
* **工程落地点**：
  * [create_dwd.sql](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/sql/create_dwd.sql#L178-L245)（`dwd.fact_student_vle` 构建）
  * [load_dwd.py](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/scripts/load_dwd.py#L238-L300)（点击量绝对守恒与 0 孤儿门禁）

---

### 5. 跨事实域轻度汇总宽表深挖：两步对齐架构、异构考评归一化与公历时序锚点治理
* **面试官追问**：“跨多张千万级事实表构建宽表时，如何避免笛卡尔积膨胀？如何处理异构考核大纲（有/无期末考、权重缺失）导致的学生成绩失真？跨学期的相对时间序列如何科学去重？”
* **核心对答点**：
  1. **两步对齐架构（Two-step CTE Alignment）**：在 [create_dws.sql](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/sql/create_dws.sql) 中，拒绝直接多表级联 JOIN。先通过 CTE 将考评明细（17.4 万行）与 VLE 交互流水（846 万行）分别按 `(student_key, course_key)` 预聚合，再以选课主干（32,593 行）平铺打宽，耗时仅 1.6s，彻底杜绝数据膨胀并实现毫秒级下游单表查询。
  2. **异构考评大纲治理与 100 分制学术归一化**：
     - **揭示口径缺陷**：深入发现传统暴力累加把期末考试（Exam）混入平时成绩，导致 CCC/DDD 课程 3,949 名学生得分突破 100 分（最高达 200 分），且导致无权重课程 GGG 学生全员 0 分假学渣的严重口径污染。
     - **三元度量分权与动态路由归一化**：将指标拆解为纯平时加权分 `ca_weighted_score`（排除 Exam，上限 100）、期末考卷面分 `exam_score`（0~100）及综合学术得分 `course_academic_score`（0~100）。针对三类大纲动态路由：无期末考课程取平时分；有期末考课程按平时与期末各 50% 归一化；无权重课程取平时作业等权均分。实测 Distinction 稳定在 82~90 分，Pass 稳定在 62~80 分，Fail 稳定在 15~44 分，全员严格收敛至 [0.00, 100.00]，彻底保障了跨课程 GPA 与 ADS 排名的真实性。
  3. **跨学期相对时序向物理公历锚点对齐（Active Days 时序治理）**：
     - **发现相对时间去重缺陷**：原始数据仅记录相对开课天数 `interaction_day_offset`，若直接跨课程去重，会导致跨学期选课学生在不同年份的“第 10 天”被错误合并，导致 1,991 名学生的活跃天数被系统性严重低估。
     - **公历锚点对齐架构**：基于学期规范（B 为 2 月，J 为 10 月）构建物理锚点日期，利用 PostgreSQL 原生 `anchor_date + interaction_day_offset` 还原真实公历日。既实现了同考期多选课学生的物理天精准合并，又杜绝了跨考期误吞，实测 Index Only Scan 5.7 秒完成 846 万行极速去重。
  4. **事务提交前 19 重守恒门禁**：在 [load_dws.py](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/scripts/load_dws.py) 单事务中执行门禁，确保 39,605,099 次平台点击、32,593 选课人次与 173,912 条考评记录绝对守恒，学术分 100% 处于 [0, 100] 合法区间，异常自动 ROLLBACK。
* **工程落地点**：
  * [create_dws.sql](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/sql/create_dws.sql)（DWS 3 张核心实体宽表构建）
  * [load_dws.py](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/scripts/load_dws.py)（19 重 Pre-commit 守恒门禁与自动化校验）

---

### 6. 维度与事实边界哲学深挖：静态配置维度（客体） vs 动态行为事实（主体）
* **面试官追问**：“在你们的 DWD 明细层中，为什么事实表全部以学生（Student）为主语，而没有单独的课程事实表（如 Course Enrollment / Course Assessment / Course VLE）？课程视角的主题表在何时才会出现？”
* **核心对答点**：
  1. **主体与客体的行为哲学（第一性原理）**：在现实业务中，客观发生的动态流水事件必然由**行为主体（学生）**主动发起（学生选课、学生交卷、学生点击）。课程（Course）、考题大纲（Assessment）、平台资源（VLE）是教务处预设的**静态配置元数据（客体与环境）**，在数仓中归属于 **DIM 维度层**。
  2. **星型模型枢纽连结**：DWD 事实表本质是连结各大维度的业务事件枢纽。所谓“选课事件”，就是学生维度与课程维度的多对多联结，已内嵌 `course_key`，命名为 `fact_student_enrollment` 还是 `fact_course_enrollment` 在物理明细上是同一张表，无需重复冗余。
  3. **课程主语的诞生时机（DWS / ADS）**：只有到了 **DWS 轻度汇总层** 与 **ADS 应用层**，当业务需要抹平学生个体差异、将海量流水按课程开设班次（22 行）进行上卷聚合（Roll-up）时，以 Course 为主语的经营宽表（如 `course_presentation_summary`）才正式诞生。
* **工程落地点**：
  * [sql/create_dim.sql](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/sql/create_dim.sql)（静态大纲配置维表）
  * [sql/create_dwd.sql](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/sql/create_dwd.sql)（学生行为事务事实表）
  * [sql/create_dws.sql](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/sql/create_dws.sql)（课程主题上卷聚合表）

---

### 7. 指标统计陷阱深挖：辛普森悖论与幸存者偏差（全口径 vs 有效结课口径）
* **面试官追问**：“在你们的指标设计中，全校大盘学术均分仅为 43.71 分，而及格线是 40 分，为什么这个均分如此贴近及格线？你们是如何识别并治理统计偏差的？”
* **核心对答点**：
  1. **警惕统计学辛普森悖论与幸存者偏差**：全校大盘均分 43.71 分贴近及格线，并不是在读学生学术能力差（在读通过群体 Pass+Distinction 均分高达 73.82 分，优秀生高达 86.62 分）；而是因为开放大学有高达 31.16% 的中途辍学退学群体（Withdrawn，生均仅 6.87 分）和 21.64% 的挂科生（Fail，生均 26.00 分），两项合计占总人次的 52.80%（超过半数！），在全局大盘计算中产生了强烈的拉低效应。
  2. **ADS 双口径设计与学情分群决策**：在 ADS 应用层明确区分“全口径学术均分（43.71 分，评估宏观办学流失挑战）”与“有效结课学术均分（73.82 分，评估真实教学质量水平）”双重标尺，并对非及格群体展开学业失联与拖延归因，为教务辅导员精准识别高危辍学学生提供了决定性的量化依据。
* **工程落地点**：
  * [sql/create_dws.sql](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/sql/create_dws.sql)（`dws.student_course_summary` 与 `dws.course_presentation_summary`）
  * [scripts/load_dws.py](file:///Users/johnnbb/Desktop/project/oulad-learning-dw/scripts/load_dws.py)（学业分群画像与均分校验）

## 三、版本迭代记录

| 版本号 | 日期 | 覆盖范围 | 变更摘要 |
| :--- | :--- | :--- | :--- |
| **v1.0** | 2026-10-08 | ODS, STG, DIM, DWD(选课/考核) | 完成基础接入、Kimball 代理键、逻辑外键解耦、累积快照事实表与 Pre-commit 原子质量门禁提炼。 |
| **v1.1** | 2026-10-08 | DWD(平台交互表) | 落地 845 万行 VLE 交互明细事实表（日粒度收敛消除 219 万碎行，3960 万点击量绝对守恒）。 |
| **v1.2** | 2026-10-09 | DWS(轻度汇总宽表矩阵) | 落地 DWS 3 大核心实体宽表（单科选课 3.2w 行、全生命周期 2.8w 行、课程运营 22 行），口径真实性治理与 19 重守恒门禁全部跑通。 |
| *v1.3* (待推进) | 待定 | ADS(应用层看板与特征工程) | 推进 ADS 层学业预警大屏、流失归因宽表与 PySpark 分布式滑动窗口周特征提取。 |
