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

## 三、版本迭代记录

| 版本号 | 日期 | 覆盖范围 | 变更摘要 |
| :--- | :--- | :--- | :--- |
| **v1.0** | 2026-10-08 | ODS, STG, DIM, DWD(选课/考核) | 完成基础接入、Kimball 代理键、逻辑外键解耦、累积快照事实表与 Pre-commit 原子质量门禁提炼。 |
| **v1.1** | 2026-10-08 | DWD(平台交互表) | 落地 845 万行 VLE 交互明细事实表（日粒度收敛消除 219 万碎行，3960 万点击量绝对守恒）。 |
| *v1.2* (待推进) | 待定 | DWS, ADS, 特征工程 | 补充学生全生命周期综合宽表与 PySpark 分布式滑动窗口周活跃度提取。 |
