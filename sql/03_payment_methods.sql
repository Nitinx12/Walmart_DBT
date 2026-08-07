/*
===============================================================================
Report Name : Payment Method Revenue Analysis
Purpose     : Analyze revenue contribution by payment method.
Author      : Nitin
Layer       : Gold
Database    : PostgreSQL
Created     : 2026-08-02

Description:
- Aggregates total revenue for each payment method.
- Calculates each payment method's percentage of total revenue.
- Sorts payment methods by highest revenue.

===============================================================================
*/

WITH payment_base AS (
    SELECT
        p.payment_method_id,
        INITCAP(p.payment_method_name) AS payment_method_name,
        SUM(oi.line_amount) AS total_amount
    FROM gold.dim_payment_methods AS p
    LEFT JOIN gold.dim_orders AS o
        ON p.payment_method_id = o.payment_method_id
    LEFT JOIN gold.fact_order_items AS oi
        ON o.order_id = oi.order_id
    GROUP BY
        p.payment_method_id,
        payment_method_name
),

grand_revenue AS (
    SELECT SUM(total_amount) AS total_revenue
    FROM payment_base
)

SELECT
    p.payment_method_name,
    p.total_amount,
    ROUND(p.total_amount / gr.total_revenue * 100, 2) AS pct_of_total
FROM payment_base AS p
CROSS JOIN grand_revenue AS gr
ORDER BY pct_of_total DESC
