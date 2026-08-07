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

WITH cate_base AS (
    SELECT
        c.category_id,
        c.category_name,
        SUM(oi.line_amount) AS total_amount
    FROM gold.dim_categories AS c
    LEFT JOIN gold.dim_products AS p
        ON c.category_id = p.category_id
    LEFT JOIN gold.fact_order_items AS oi
        ON p.product_id = oi.product_id
    GROUP BY
        c.category_id,
        c.category_name
),

grand_total AS (
    SELECT SUM(total_amount) AS grand_revenue
    FROM cate_base
)

SELECT
    c.category_name,
    c.total_amount,
    ROUND(c.total_amount / gt.grand_revenue * 100, 2) AS pct_of_total
FROM cate_base AS c
CROSS JOIN grand_total AS gt
