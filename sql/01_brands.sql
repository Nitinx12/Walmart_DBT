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

WITH brand_base AS (
    SELECT
        b.brand_id,
        b.brand_name,
        SUM(oi.line_amount) AS total_amount
    FROM gold.dim_brands AS b
    LEFT JOIN gold.dim_products AS p
        ON
            b.brand_id = p.brand_id
    LEFT JOIN gold.fact_order_items AS oi
        ON
            p.product_id = oi.product_id
    GROUP BY
        b.brand_id,
        b.brand_name
),

grand_revenue AS (
    SELECT SUM(total_amount) AS grand_revenue
    FROM brand_base
)

SELECT
    b.brand_name,
    b.total_amount,
    ROUND(b.total_amount / gr.grand_revenue * 100, 2) AS pct_of_total
FROM brand_base AS b
CROSS JOIN grand_revenue AS gr
ORDER BY pct_of_total DESC;
