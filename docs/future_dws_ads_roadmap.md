# OULAD 数仓 DWS 汇总层与 ADS 应用层规划蓝图 (Roadmap & Blueprint)

> **文档定位**：本文档记录 OULAD 学习分析数仓从**“底层客观明细层（DIM/DWD）”**向**“上层业务赋能与算法支撑（DWS/ADS）”**跃迁的完整架构设计。
> 包含 **3 张 DWS 主题宽表** 与 **3 张 ADS 场景应用表** 的声明粒度、字段清单、指标计算口径与下游应用价值，作为后续开发实施的指导蓝图与技术底稿。

---

## 一、分层架构全局概览

```text
[DWD 明细事实层]
├── fact_student_enrollment   (选课累积快照，32,593 行)
├── fact_student_assessment   (考核提交事务，173,912 行)
└── fact_student_vle          (平台交互日汇总，8,459,320 行)
           │
           ▼
[DWS 轻度汇总层] —— 【通用的中台资产，面向分析主题，追求全、广、可复用】
├── 1. dws.dws_student_course_summary      (粒度: 学生 x 课程开设，32,593 行) ➔ 【核心王牌宽表】
├── 2. dws.dws_student_lifetime_summary    (粒度: 独立学生，28,785 行)       ➔ 【全生涯累积宽表】
└── 3. dws.dws_course_presentation_summary(粒度: 课程开设，22 行)          ➔ 【教学成效宽表】
           │
           ▼
[ADS 应用数据层] —— 【定制的业务成品，面向特定终端，追求薄、快、开箱即用】
├── 1. ads.ads_course_teaching_kpi         (大屏看板) ➔ 毫秒级展示课程及格率红黑榜与群体画像
├── 2. ads.ads_student_at_risk_warning     (预警雷达) ➔ 辅导员红黄绿风险名单与失联/拖延归因
└── 3. ads.ads_student_churn_features      (算法集市) ➔ 机器学习挂科/退学预测标准特征矩阵 (Feature Store)
```

---

## 二、DWS 轻度汇总层设计规范（3 张主题宽表）

### 1. 【核心王牌】学生单科选课综合画像宽表：`dws.dws_student_course_summary`
* **声明粒度**：一名学生修读一次课程开设，占一行（`student_key x course_key`）。
* **预期行数**：严格与选课事实表对齐，共 **32,593 行**。
* **业务定位**：全仓最核心的资产。打通四大域（学生画像、选课生命周期、考核学业分、平台行为），下游单表查询替代 845 万行交互与 17 万行考核的多表 JOIN。

#### 字段设计与计算口径：
| 字段分类 | 字段名 | 类型 | 来源 / 计算逻辑 | 业务说明 |
| :--- | :--- | :--- | :--- | :--- |
| **主键标识** | `student_key` | `INTEGER` | `fact_student_enrollment` | 学生代理主键 |
| | `course_key` | `INTEGER` | `fact_student_enrollment` | 课程开设代理主键 |
| **学生画像域** | `gender` | `VARCHAR(10)` | `dim_student` | 性别 |
| | `region` | `VARCHAR(64)` | `dim_student` | 地理区域 |
| | `highest_education` | `VARCHAR(64)` | `dim_student` | 入学最高学历 |
| | `imd_band` | `VARCHAR(20)` | `dim_student` | 贫困指数区间 |
| | `has_disability` | `BOOLEAN` | `dim_student` | 残疾声明 |
| **选课状态域** | `age_band_for_presentation`| `VARCHAR(20)` | `fact_student_enrollment` | 选课时年龄段 |
| | `num_of_prev_attempts`| `INTEGER` | `fact_student_enrollment` | 此前重修本门课次数 |
| | `studied_credits` | `INTEGER` | `fact_student_enrollment` | 本学期修读总学分 |
| | `registration_day_offset` | `INTEGER` | `fact_student_enrollment` | 注册相对天数 |
| | `unregistration_day_offset`| `INTEGER` | `fact_student_enrollment` | 退课相对天数（未退为NULL） |
| | `final_result` | `VARCHAR(20)` | `fact_student_enrollment` | 考核结果 (Pass/Fail/Withdrawn) |
| **考核学业表现**<br>(来自 assessment 聚合) | `total_assessments_taken` | `INTEGER` | `COUNT(assessment_key)` | 本门课参与考核记录数 |
| | `passed_assessment_count` | `INTEGER` | `COUNT(CASE WHEN is_passed THEN 1 END)` | 及格考核次数 |
| | `late_assessment_count` | `INTEGER` | `COUNT(CASE WHEN submission_delay_days > 0 THEN 1 END)` | 迟交作业次数 |
| | `avg_assessment_score` | `NUMERIC(5,2)` | `ROUND(AVG(score), 2)` | 考核平均原始分 |
| | `accumulated_weighted_score` | `NUMERIC(5,2)` | `ROUND(SUM(weighted_score), 2)` | **平时成绩累计加权总分** |
| | `avg_submission_delay_days` | `NUMERIC(5,2)` | `ROUND(AVG(submission_delay_days), 2)` | 平均逾期天数（拖延倾向） |
| **平台交互活跃**<br>(来自 vle 聚合) | `total_vle_clicks` | `INTEGER` | `COALESCE(SUM(click_count), 0)` | **平台总点击交互量** |
| | `active_vle_days` | `INTEGER` | `COUNT(DISTINCT interaction_day_offset)` | **平台实际上线活跃天数** |
| | `pre_course_clicks` | `INTEGER` | `SUM(CASE WHEN is_pre_course_activity THEN click_count ELSE 0 END)` | 开课前自主预习点击量 |
| | `forum_clicks` | `INTEGER` | 关联 `dim_vle` 筛选 `activity_type='forumng'` 的点击和 | 论坛交流讨论点击量 |
| | `content_clicks` | `INTEGER` | 关联 `dim_vle` 筛选 `activity_type='oucontent'` 的点击和 | 课件核心学习点击量 |

---

### 2. 【学生全景】学生全生命周期累积画像宽表：`dws.dws_student_lifetime_summary`
* **声明粒度**：一个独立学生占一行（`student_key`）。
* **预期行数**：严格与学生维表对齐，共 **28,785 行**。
* **业务定位**：管理学生在整个大学（Bachelor 生涯）跨学期、跨年份的综合学业资产，用于长期学籍管理与毕业画像。

#### 核心指标清单：
* `total_courses_enrolled`：大学累计选课门数；
* `total_courses_passed`：大学累计通过课程数；
* `total_courses_withdrawn`：大学累计中途退课门数；
* `course_pass_rate`：大学整体选课通过率（`passed / enrolled`）；
* `lifetime_total_credits`：大学累计所修总学分；
* `lifetime_avg_gpa`：大学全科平均成绩加权绩点；
* `lifetime_total_clicks`：大学四年在线平台总点击数；
* `lifetime_total_active_days`：大学四年累计上线天数。

---

### 3. 【教学成效】课程开设运营与教学成效分析宽表：`dws.dws_course_presentation_summary`
* **声明粒度**：一次课程开设占一行（`course_key`）。
* **预期行数**：共 **22 行**。
* **业务定位**：教务处宏观教学管理看板，评估各学期课程运营质量与学生学习负荷。

#### 核心指标清单：
* `total_enrolled_students`：该门课总选课人数；
* `total_withdrawn_students`：中途退课人数；
* `withdrawn_rate`：退课率（`withdrawn / enrolled`）；
* `passed_students`：及格人数；
* `pass_rate`：及格率（`passed / enrolled`）；
* `distinction_rate`：优秀率（`distinction / enrolled`）；
* `avg_final_score`：全班平均期末综合分；
* `avg_student_clicks`：生均平台点击量；
* `avg_forum_participation`：生均论坛参与活跃度。

---

## 三、ADS 应用数据层设计规范（3 张场景成品表）

### 1. 【面向领导大屏】教务教学质量决策驾驶舱：`ads.ads_course_teaching_kpi`
* **目标终端**：ECharts / Metabase 领导大屏看板。
* **数据规模**：几十行，支持毫秒级高并发点查。
* **应用内容**：
  * **课程红黑榜**：按及格率从高到低、退课率从高到低快速排序；
  * **群体公平性分析**：按贫困指数（IMD Band）分群，统计不同阶层学生的及格率方差；
  * **学业投入产出比**：平台点击量区间与期末高分率的联动分布。

---

### 2. 【面向辅导员干预】学业风险早警雷达榜单：`ads.ads_student_at_risk_warning`
* **目标终端**：教务辅导员日常工作台、学业预警邮件自动推送系统。
* **预警策略引擎（规则固化）**：
  * **高危预警（Red Alert）**：
    `accumulated_weighted_score < 40` 且 `active_vle_days 处于后 10% 分位数`；
  * **中危预警（Yellow Alert）**：
    `late_assessment_count >= 2`（多次迟交），或开课第 30 天前总点击量小于 20 次；
  * **健康在读（Green Normal）**：各项指标处于平均水准以上。
* **输出字段**：
  `student_key, course_key, id_student, risk_level (高危/中危/正常), primary_risk_factor (失联型/拖延型/基础薄弱型), action_recommendation (辅导员约谈/延期补考/课后辅导)`。

---

### 3. 【面向算法工程师】挂科与退学预测特征矩阵：`ads.ads_student_churn_features`
* **目标终端**：Python 机器学习流水线（Pandas / Scikit-Learn / XGBoost / PySpark）。
* **数据形态**：标准特征工程格式（Feature Matrix + Label），无需二次清洗：
  * **标识列**：`student_key, course_key`；
  * **标准化数值特征**：`feat_age, feat_studied_credits, feat_prev_attempts, feat_pre_course_clicks, feat_active_days, feat_avg_delay, feat_weighted_score`；
  * **独热编码特征**：`feat_is_male, feat_has_disability`；
  * **预测目标（Label）**：
    * `label_is_withdrawn (0/1)`：是否中途退学；
    * `label_is_failed (0/1)`：是否挂科。

---

## 四、后续实施步骤与技术路线

1. **第一阶段：构建 `dws.dws_student_course_summary`（核心王牌宽表）**
   * 编写 `sql/create_dws.sql`，通过优雅的 CTE 将事实表和维表联结聚合；
   * 编写 `scripts/load_dws.py`，加入动态行数（32,593 行）与点击量守恒核验。
2. **第二阶段：构建其余两张 DWS 宽表（学生生涯 + 课程表现）**
   * 向上聚合，形成完整的 DWS 三重奏。
3. **第三阶段：构建 ADS 三大应用集市（驾驶舱 + 预警雷达 + 算法特征）**
   * 编写 `sql/create_ads.sql` 与配套装载脚本，完成数仓从源头到业务价值的完整闭环。
