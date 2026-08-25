/*
===============================================================================
Query Name : No Sales Date Analysis
Layer      : Gold
Difficulty : Advanced
===============================================================================

Purpose:
Identify dates on which no sales occurred by generating a complete calendar
between the first and last order date.

Description:
- Generates a continuous calendar using GENERATE_SERIES().
- Includes every calendar date regardless of sales activity.
- Joins the generated calendar with completed orders.
- Identifies dates with zero completed orders.
- Returns sales metrics for every date, including days without sales.

Business Applications:
- Detect system outages
- Identify holiday closures
- Monitor ETL failures
- Analyze sales gaps
- Validate data completeness

Required Output:

• Sales Date
• Total Orders
• Total Customers
• Total Revenue
• Sales Status
    - Sales Day
    - No Sales

Sort by Sales Date.

Source Tables:
    gold.dim_orders
    gold.fact_order_items

Author      : Nitin
Created On  : 2026-08-06
===============================================================================
*/

WITH calendar_base AS (
    SELECT
        GENERATE_SERIES(
            (
                SELECT MIN(order_timestamp)::DATE
                FROM gold.dim_orders
            ),
            (
                SELECT MAX(order_timestamp)::DATE
                FROM gold.dim_orders
            ),
            INTERVAL '1 day'
        )::DATE AS sales_date
),

daily_sales AS (
    SELECT
        o.order_timestamp::DATE AS sales_date,
        COUNT(DISTINCT o.order_id) AS total_orders,
        COUNT(DISTINCT o.customer_id) AS total_customers,
        ROUND(SUM(oi.line_amount), 2) AS total_revenue
    FROM gold.dim_orders AS o
    INNER JOIN gold.fact_order_items AS oi
        ON o.order_id = oi.order_id
    WHERE o.order_status = 'Completed'
    GROUP BY
        o.order_timestamp::DATE
)

SELECT
    c.sales_date,
    COALESCE(ds.total_orders, 0) AS total_orders,
    COALESCE(ds.total_customers, 0) AS total_customers,
    COALESCE(ds.total_revenue, 0) AS total_revenue,
    CASE
        WHEN ds.sales_date IS NULL
            THEN 'No Sales'
        ELSE 'Sales Day'
    END AS sales_status
FROM calendar_base AS c
LEFT JOIN daily_sales AS ds
    ON c.sales_date = ds.sales_date
ORDER BY
    c.sales_date;