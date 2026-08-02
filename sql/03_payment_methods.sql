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

WITH payment_base AS(
    SELECT
        P.payment_method_id,
        INITCAP(P.payment_method_name)  AS payment_method_name,
        SUM(OI.line_amount)             AS total_amount
    FROM gold.dim_payment_methods AS P
    LEFT JOIN gold.dim_orders AS O
        ON O.payment_method_id = P.payment_method_id
    LEFT JOIN gold.fact_order_items AS OI
        ON OI.order_id = O.order_id
    GROUP BY
        P.payment_method_id,
        payment_method_name
),
grand_revenue AS(
    SELECT SUM(total_amount) AS total_revenue
    FROM payment_base
)
SELECT
    P.payment_method_name,
    P.total_amount,
    ROUND(P.total_amount / GR.total_revenue * 100,2) AS pct_of_total
FROM payment_base AS P
CROSS JOIN grand_revenue AS GR
ORDER BY pct_of_total DESC


