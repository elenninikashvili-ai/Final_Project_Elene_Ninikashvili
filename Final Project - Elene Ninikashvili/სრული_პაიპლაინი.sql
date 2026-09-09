-- Databricks notebook source
-- MAGIC %md
-- MAGIC # საკრედიტო პორტფელის რისკზე მორგებული მომგებიანობა
-- MAGIC სრული პაიფლაინი

-- COMMAND ----------

-- პირველ რიგში შევმქენით RAW სქემა და ავტვირთე დაუმუშავებელი მონაცემები ექსელის ფაილით და ცხრილს დავარქვი lc_loan_accepted, სადაც იყო 2260701 მონაცემი

CREATE SCHEMA IF NOT EXISTS getdata.raw
COMMENT 'Final project - Elene Ninikashvili: unmodified source data';


-- COMMAND ----------

-- MAGIC %md
-- MAGIC ამის შემდეგ დავიწყე მონაცემების შესწავლა და გატესტვა

-- COMMAND ----------

-- შევამოწმე დუბლიკატები იყო თუ არა, არ იყო
WITH id_counts AS (
    SELECT id, COUNT(*) AS occurrence_count
    FROM getdata.raw.lc_loan_accepted
    WHERE id IS NOT NULL
    GROUP BY id
)
SELECT
    COUNT(*)                                                        AS distinct_id_count,
    SUM(CASE WHEN occurrence_count > 1 THEN 1 ELSE 0 END)           AS duplicate_count
FROM id_counts;

-- COMMAND ----------

-- ჩემი რეპორტისთვის მჭირდებოდა მხოლოდ დასრულებული სესხები, გადავამოწმე წლების მიხედვით დასრულებული სესხების პროცენტულობა.
-- სადაც 36 თვიანებშიც და 60 თვიანებშიც დასრულებული სესხები პროცენტულობა ყველაზე მაღალი იყო 2011-2015 წლებში. ამიტომ ავიღე რეპორტში ეს რეინჯი

SELECT
    TRIM(term)                                                      AS loan_term,
    YEAR(TO_DATE(issue_d, 'MMM-yyyy'))                              AS issue_year,
    COUNT(*)                                                        AS issued_count,
    ROUND(
        100.0 * SUM(CASE
                        WHEN loan_status IN ('Fully Paid', 'Charged Off')
                        THEN 1 ELSE 0
                    END) / COUNT(*), 1
    )                                                                AS completed_pct
FROM getdata.raw.lc_loan_accepted
WHERE issue_d IS NOT NULL
GROUP BY TRIM(term), YEAR(TO_DATE(issue_d, 'MMM-yyyy'))
ORDER BY loan_term, issue_year;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ვქმნით ცხრილებს

-- COMMAND ----------

CREATE OR REPLACE TABLE getdata.calculated.dim_lc_grade
COMMENT 'რისკის კატეგორიები და ქვეკატეგორიები რიგითობითა და რისკის დონით'
AS
WITH distinct_grades AS (
    SELECT DISTINCT
        grade                                   AS grade_code,
        sub_grade                               AS sub_grade_code
    FROM getdata.raw.lc_loan_accepted
    WHERE grade     IS NOT NULL
      AND sub_grade IS NOT NULL
)
SELECT
    dg.sub_grade_code,
    dg.grade_code,
    ASCII(dg.grade_code) - ASCII('A') + 1                           AS grade_sort_order,
    (ASCII(dg.grade_code) - ASCII('A')) * 5
        + CAST(SUBSTRING(dg.sub_grade_code, 2, 1) AS INT)           AS sub_grade_sort_order,
    CASE
        WHEN dg.grade_code IN ('A', 'B') THEN 'დაბალი რისკი'
        WHEN dg.grade_code IN ('C', 'D') THEN 'საშუალო რისკი'
        ELSE                                  'მაღალი რისკი'
    END                                                              AS risk_tier
FROM distinct_grades dg;

-- COMMAND ----------

CREATE OR REPLACE TABLE getdata.calculated.dim_lc_purpose
COMMENT 'სესხის დანიშნულება: ქართული სახელები და ჯგუფები'
AS
WITH distinct_purposes AS (
    SELECT DISTINCT purpose AS purpose_code
    FROM getdata.raw.lc_loan_accepted
    WHERE purpose IS NOT NULL
)
SELECT
    dp.purpose_code,
    CASE dp.purpose_code
        WHEN 'debt_consolidation' THEN 'ვალის კონსოლიდაცია'
        WHEN 'credit_card'        THEN 'საკრედიტო ბარათის დაფარვა'
        WHEN 'home_improvement'   THEN 'სახლის რემონტი'
        WHEN 'house'              THEN 'საცხოვრებლის შეძენა'
        WHEN 'major_purchase'     THEN 'მსხვილი შესყიდვა'
        WHEN 'car'                THEN 'ავტომობილი'
        WHEN 'vacation'           THEN 'შვებულება'
        WHEN 'wedding'            THEN 'ქორწილი'
        WHEN 'moving'             THEN 'გადაადგილება'
        WHEN 'small_business'     THEN 'მცირე ბიზნესი'
        WHEN 'medical'            THEN 'სამედიცინო ხარჯი'
        WHEN 'educational'        THEN 'განათლება'
        WHEN 'renewable_energy'   THEN 'განახლებადი ენერგია'
        WHEN 'other'              THEN 'სხვა'
    END                                                              AS purpose_name,
    CASE
        WHEN dp.purpose_code IN ('debt_consolidation', 'credit_card')
            THEN 'ვალის რეფინანსირება'
        WHEN dp.purpose_code IN ('home_improvement', 'house')
            THEN 'საცხოვრებელი'
        WHEN dp.purpose_code IN ('major_purchase', 'car', 'vacation', 'wedding', 'moving')
            THEN 'სამომხმარებლო'
        WHEN dp.purpose_code = 'small_business'
            THEN 'ბიზნესი'
        WHEN dp.purpose_code IN ('medical', 'educational', 'renewable_energy', 'other')
            THEN 'სხვა დანიშნულება'
    END                                                              AS purpose_group
FROM distinct_purposes dp;

-- COMMAND ----------

-- შევამოწმოთ რომ ორივე შეიქმნა
SELECT * FROM getdata.calculated.dim_lc_grade;

SELECT * FROM getdata.calculated.dim_lc_purpose;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ვქმნით მთავარ ფაქტებიც ცხრილს

-- COMMAND ----------

-- შევქმენი fct_lc_loan_performance ცხრილი, მხოლოდ დასრულებულ სესხებზე, გასუფთავებული ველებით.

-- ჯერ ვქმნით ტემპორარი v_scoped_loans ვიუს, რომ შემდეგ შევქმნათ ცხრილი fct_lc_loan_performance
CREATE OR REPLACE TEMPORARY VIEW v_scoped_loans AS
SELECT *
FROM getdata.raw.lc_loan_accepted
WHERE issue_d IS NOT NULL
  AND loan_status IN ('Fully Paid', 'Charged Off')
  AND (
        (TRIM(term) = '36 months' AND YEAR(TO_DATE(issue_d, 'MMM-yyyy')) BETWEEN 2011 AND 2015)
     OR (TRIM(term) = '60 months' AND YEAR(TO_DATE(issue_d, 'MMM-yyyy')) BETWEEN 2011 AND 2013)
      );

-- COMMAND ----------

CREATE OR REPLACE TABLE getdata.calculated.fct_lc_loan_performance
COMMENT 'ერთი სტრიქონი = ერთი დასრულებული სესხი. მომწიფებული კოჰორტები: 36თვე 2011-2015, 60თვე 2011-2013.'
AS
SELECT

    id                                                              AS loan_id,

    YEAR(TO_DATE(issue_d, 'MMM-yyyy'))                             AS issue_year,
    QUARTER(TO_DATE(issue_d, 'MMM-yyyy'))                          AS issue_quarter,

    CAST(REGEXP_EXTRACT(term, '(\\d+)', 1) AS INT)                 AS term_months,
    grade                                                           AS grade_code,
    sub_grade                                                       AS sub_grade_code,
    purpose                                                         AS purpose_code,
    addr_state                                                      AS state_code,

    funded_amnt                                                     AS funded_amount,

    CAST(REPLACE(CAST(int_rate AS STRING), '%', '') AS DOUBLE)     AS interest_rate,
    CASE
        WHEN emp_length IS NULL                                          THEN 'უცნობი'
        WHEN emp_length = '< 1 year'                                     THEN '1 წლამდე'
        WHEN emp_length = '10+ years'                                    THEN '10+ წელი'
        WHEN emp_length IN ('1 year', '2 years', '3 years')              THEN '1-3 წელი'
        WHEN emp_length IN ('4 years', '5 years', '6 years')             THEN '4-6 წელი'
        ELSE                                                                  '7-9 წელი'
    END                                                             AS emp_length_band,
    CASE
        WHEN dti IS NULL OR dti < 0 OR dti >= 999 THEN NULL
        ELSE dti
    END                                                             AS dti,

    CASE WHEN loan_status = 'Charged Off' THEN TRUE ELSE FALSE END AS is_charged_off,
    (total_rec_int + total_rec_late_fee)                            AS interest_income,

    (funded_amnt - total_rec_prncp - recoveries + collection_recovery_fee)
                                                                     AS net_principal_loss,

    (
        (total_rec_int + total_rec_late_fee)
        - (funded_amnt - total_rec_prncp - recoveries + collection_recovery_fee)
    )                                                                AS net_result,

    ROUND(
        (
            (total_rec_int + total_rec_late_fee)
            - (funded_amnt - total_rec_prncp - recoveries + collection_recovery_fee)
        ) / funded_amnt * 100, 2
    )                                                                AS net_margin_pct,

    CASE
        WHEN loan_status = 'Charged Off' AND last_pymnt_d IS NOT NULL
            THEN MONTHS_BETWEEN(
                     TO_DATE(last_pymnt_d, 'MMM-yyyy'),
                     TO_DATE(issue_d, 'MMM-yyyy')
                 )
        ELSE NULL
    END                                                              AS months_survived,

    ROUND(total_rec_prncp / funded_amnt * 100, 1)                    AS principal_repaid_pct

FROM v_scoped_loans;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC საბოლოოდ ვამოწმებთ ჩვენს შექმნილ ცხრილს

-- COMMAND ----------

SELECT * FROM getdata.calculated.fct_lc_loan_performance

-- COMMAND ----------

-- MAGIC %md
-- MAGIC # შედეგი
-- MAGIC
-- MAGIC სამივე ცხრილი მზადაა დეშბორდისთვის:
-- MAGIC `getdata.calculated.dim_lc_grade` — 35 ქვეგრეიდი
-- MAGIC `getdata.calculated.dim_lc_purpose` — 14 დანიშნულება
-- MAGIC `getdata.calculated.fct_lc_loan_performance` — 655,488 სესხი
-- MAGIC
-- MAGIC ამ სამ ცხრილზე ავაგე დანარჩენი დეშბორდის Dataset-ები (LoanDetail, SubGradePerformance,
-- MAGIC GradeMixByYear, MarginVsDefaultChange, DisplayModeOptions)
-- MAGIC