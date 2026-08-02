/*
===============================================================================
Report Name : Category Revenue Analysis
Purpose     : Analyze revenue contribution by product category.
Author      : Nitin
Layer       : Gold
Database    : PostgreSQL
Created     : 2026-08-02

Description:
- Aggregates total revenue for each category.
- Calculates each category's percentage of total revenue.
- Sorts categories by highest revenue.

===============================================================================
*/

WITH cate_base AS(
    SELECT
        C.category_id,
        C.category_name,
        SUM(OI.line_amount) AS total_amount
    FROM gold.dim_categories AS C
    LEFT JOIN gold.dim_products AS P
        ON P.category_id = C.category_id
    LEFT JOIN gold.fact_order_items AS OI
        ON OI.product_id = P.product_id
    GROUP BY
        C.category_id,
        C.category_name
),
grand_total AS(
    SELECT SUM(total_amount) AS grand_revenue
    FROM cate_base
)
SELECT
    C.category_name,
    C.total_amount,
    ROUND(C.total_amount / GT.grand_revenue * 100,2) AS pct_of_total
FROM cate_base AS C
CROSS JOIN grand_total AS GT


