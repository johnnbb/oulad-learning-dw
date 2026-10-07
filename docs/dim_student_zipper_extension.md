# 学生维度表（dim_student）拉链表扩展设计与演进方案

> **文档定位**：本文档记录 OULAD 数仓项目向生产级日常增量场景演进时，如何将静态学生维度表升级为 **SCD2（缓慢变化维第二类）拉链表**。用于加深对数仓底层历史变更追踪的理解，并作为简历与面试的深度加分项。

---

## 1. 现状回顾：为什么当前 OULAD 采用静态全量维表（SCD1）？

- **当前场景**：OULAD 数据集是英国开放大学某几个学期的离线归档切片，数据为单次批处理交付，没有业务系统每天推过来的增量变更日志（如 CDC / `ods_student_inc`）。
- **当前设计**：采用星型模型中的静态维度宽表，直接合并 `student_info` 与 `student_registration`。
- **警醒与思考**：
  在真实企业生产中，学生/用户的属性是会**随时间频繁动态变化**的（例如：中途申请休学/退课、家庭地址或地区变更、残疾状态变更、获得阶段性学分等）。如果直接在原表上覆盖更新，就会丢失历史轨迹，无法做时间旅行（Time Travel）分析。

---

## 2. 生产演进：如果每天有学生变更数据，如何设计拉链表？

参考业界电商数仓（如《尚硅谷电商数仓》`dim_user_zip`）规范，将 `dim_student` 升级为 `dim_student_zip`。

### 2.1 表结构设计（增加生命周期闭合字段）

```sql
CREATE TABLE dwd.dim_student_zip (
    code_module           TEXT,
    code_presentation     TEXT,
    id_student            TEXT,
    gender                TEXT,
    region                TEXT,
    highest_education     TEXT,
    imd_band              TEXT,
    age_band              TEXT,
    num_of_prev_attempts  INTEGER,
    studied_credits       INTEGER,
    disability            TEXT,
    date_registration     INTEGER,
    date_unregistration   INTEGER,
    is_withdrawn          BOOLEAN,
    final_result          TEXT,
    
    -- ===== 拉链表核心生命周期字段 =====
    start_date            DATE,        -- 该状态的生效起始日期
    end_date              DATE         -- 该状态的失效日期（当前最新有效为 9999-12-31）
);
```

---

## 3. 拉链表的核心装载流转机制

在数仓中，拉链表解决的痛点是：**大数据文件（如 ORC/Parquet）不支持随机行 UPDATE，如何通过纯只读和追加实现“修改过期时间”？**

### 3.1 首日全量装载（Day 1）
- **数据来源**：首次上线时业务全量快照。
- **装载规则**：所有当前记录的 `start_date = '上线首日'`, `end_date = '9999-12-31'`。
- **业务含义**：全量学生档案处于“当前最新有效”状态。

### 3.2 每日增量合并装载（Day N）与“改时间”原理

假设昨天是 `2026-10-05`，今天是 `2026-10-06`：
业务系统传来了今天发生信息变更（例如：学生 10001 今天办理了退课）或新注册的学生增量数据。

#### 核心三步法（无 UPDATE 纯计算闭合）：
1. **获取当日最新变更（去重）**：
   从当日增量表中按用户开窗 `ROW_NUMBER() OVER (PARTITION BY id_student ORDER BY update_time DESC)`，取当天最晚的一条变更，避免同一天多次修改。
2. **新老数据合并（UNION ALL）**：
   将“当日变更/新增数据”与“昨日处于最新状态（`end_date = 9999-12-31`）的历史数据”做全量 `UNION ALL`。
   此时发生变更的学生会出现 **2 条记录**（一条昨日存的老数据，一条今日最新数据）。
3. **开窗分流与“动态改时间”**：
   按学生开窗 `ROW_NUMBER() OVER (PARTITION BY id_student ORDER BY start_date DESC) AS rn`：
   - **`rn = 1`（最新记录）**：保留其 `end_date = '9999-12-31'`，写入最新分区；
   - **`rn = 2`（被覆盖的过期老记录）**：将其 `end_date` **动态计算赋值为昨天（2026-10-05）**，写入历史归档分区。

---

## 4. 业务使用与查询优势

有了拉链表后，下游查询可以同时支持“查最新”和“查历史切片”：

```sql
-- 场景 A：查询学生当前的最新状态（只扫 9999-12-31 分区，极速响应）
SELECT * FROM dwd.dim_student_zip 
WHERE end_date = '9999-12-31';

-- 场景 B：时间旅行！查询 2026 年 3 月 1 日开学当天学生的状态（快照还原）
SELECT * FROM dwd.dim_student_zip 
WHERE '2026-03-01' BETWEEN start_date AND end_date;
```

---

## 5. 面试警醒与表达话术

在面试中被问到：“你们这个数仓维度表怎么处理历史变化的？”：

> **标准高分回答**：
> “在当前 OULAD 离线学期归档项目中，由于源数据按学期交付且状态已固化，我们采用了规范的星型反规范化维表（SCD1）；
> 但在实际生产架构中，针对学生学籍与退课状态的渐变，我设计了基于拉链表（SCD2）的演进方案：通过设置 `start_date` 和 `end_date（9999-12-31）`，在每日增量任务中利用开窗函数进行新老版本分流，将过期记录的 `end_date` 置为昨日，不仅避免了离线数仓不可随机更新的问题，还能以极小的存储开销支持下游任意历史时点的快照还原查询。”
