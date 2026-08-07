/*
===============================================================================
Query Name : Product Ranking Analysis
Layer      : Gold
Purpose    : Rank the top-performing products within each brand based on
             completed sales revenue.

Description:
- Calculates total sales revenue for each product.
- Considers only active, completed orders.
- Uses DENSE_RANK() to rank products within each brand.
- Orders products by highest revenue, with product_id as a tie-breaker.
- Returns the Top 2 highest-revenue products for every brand.

Ranking Logic:
    Partition By : brand_name
    Order By     : total_amount DESC, product_id ASC
    Ranking Type : DENSE_RANK()

Source Tables:
    gold.dim_brands
    gold.dim_products
    gold.fact_order_items
    gold.dim_orders

Author      : Nitin
Created On  : 2026-08-03
===============================================================================
*/

WITH ranked_base AS (
    SELECT
        p.product_id,
        p.product_name,
        b.brand_name,
        SUM(oi.line_amount) AS total_amount,
        DENSE_RANK() OVER (
            PARTITION BY b.brand_name
            ORDER BY SUM(oi.line_amount) DESC, p.product_id ASC
        ) AS rnk
    FROM gold.dim_brands AS b
    INNER JOIN gold.dim_products AS p
        ON b.brand_id = p.brand_id
    INNER JOIN gold.fact_order_items AS oi
        ON p.product_id = oi.product_id
    INNER JOIN gold.dim_orders AS o
        ON oi.order_id = o.order_id
    WHERE
        o.order_status = 'Completed'
        AND o.is_active = TRUE
    GROUP BY
        p.product_id,
        p.product_name,
        b.brand_name
)

SELECT
    product_id,
    product_name,
    brand_name,
    total_amount,
    rnk
FROM ranked_base
WHERE rnk <= 2;
