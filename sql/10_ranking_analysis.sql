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
        P.product_id,
        P.product_name,
        B.brand_name,
        SUM(OI.line_amount) AS total_amount,
        DENSE_RANK() OVER (
            PARTITION BY B.brand_name
            ORDER BY SUM(OI.line_amount) DESC, P.product_id ASC
        ) AS rnk
    FROM gold.dim_brands AS B
    INNER JOIN gold.dim_products AS P
        ON P.brand_id = B.brand_id
    INNER JOIN gold.fact_order_items AS OI
        ON OI.product_id = P.product_id
    INNER JOIN gold.dim_orders AS O
        ON O.order_id = OI.order_id
    WHERE
        O.order_status = 'Completed'
        AND O.is_active = TRUE
    GROUP BY
        P.product_id,
        P.product_name,
        B.brand_name
)
SELECT
    product_id,
    product_name,
    brand_name,
    total_amount,
    rnk
FROM ranked_base
WHERE rnk <= 2;