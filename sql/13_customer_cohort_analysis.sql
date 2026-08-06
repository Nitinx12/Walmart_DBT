/*
===============================================================================
Query Name : Monthly Customer Cohort Retention Analysis
Layer      : Gold
Purpose    : Measure customer retention by monthly acquisition cohort.

Description:
- Identifies each customer's first purchase month.
- Assigns every order to a cohort month.
- Calculates the number of months since the customer's first purchase.
- Counts active customers for each cohort and month index.
- Determines the original cohort size.
- Calculates monthly retention percentage.
- Returns a cohort retention table suitable for heatmap visualization.

Source Table:
    gold.dim_orders

Author      : Nitin
Created On  : 2026-08-06
===============================================================================
*/

WITH cohort_base AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', MIN(order_timestamp)) AS cohort_month
    FROM gold.dim_orders
    GROUP BY customer_id
),
month_index AS (
    SELECT
        cb.customer_id,
        cb.cohort_month,
        (
            EXTRACT(YEAR FROM o.order_timestamp) * 12 +
            EXTRACT(MONTH FROM o.order_timestamp)
        ) -
        (
            EXTRACT(YEAR FROM cb.cohort_month) * 12 +
            EXTRACT(MONTH FROM cb.cohort_month)
        ) AS month_number
    FROM cohort_base AS cb
    INNER JOIN gold.dim_orders AS o
        ON cb.customer_id = o.customer_id
),
active_cohort AS (
    SELECT
        cohort_month,
        month_number,
        COUNT(DISTINCT customer_id) AS active_customers
    FROM month_index
    GROUP BY
        cohort_month, month_number
),
cohort_size AS (
    SELECT
        cohort_month,
        active_customers AS base_size
    FROM active_cohort
    WHERE month_number = 0
)
SELECT
    ac.cohort_month,
    ac.month_number,
    cs.base_size,
    ac.active_customers,
    ROUND(ac.active_customers * 100.0 / cs.base_size,2) AS retention_rate
FROM active_cohort AS ac
INNER JOIN cohort_size AS cs
    ON ac.cohort_month = cs.cohort_month
ORDER BY
    ac.cohort_month, ac.month_number;
