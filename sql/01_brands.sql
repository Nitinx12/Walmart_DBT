/*
===============================================================================
Report Name : Brand Revenue Analysis
Purpose     : Analyze revenue contribution by brand.
Author      : Nitin
Layer       : Gold
Database    : PostgreSQL
Created     : 2026-08-02

Description:
- Aggregates total revenue for each brand.
- Calculates each brand's percentage of total revenue.
- Sorts brands by highest revenue.

===============================================================================
*/

WITH brand_base AS(
    SELECT
        B.brand_id,
        B.brand_name,
        SUM(OI.line_amount) AS total_amount
    FROM gold.dim_brands AS B
    LEFT JOIN gold.dim_products AS P ON
        P.brand_id = B.brand_id
    LEFT JOIN gold.fact_order_items AS OI ON
        OI.product_id = P.product_id
    GROUP BY
        B.brand_id,
        B.brand_name
),
grand_revenue AS(
    SELECT SUM(total_amount) AS grand_revenue
    FROM brand_base
)
SELECT
    B.brand_name,
    B.total_amount,
    ROUND(B.total_amount / GR.grand_revenue * 100,2) AS pct_of_total
FROM brand_base AS B
CROSS JOIN grand_revenue AS GR
ORDER BY pct_of_total DESC;

