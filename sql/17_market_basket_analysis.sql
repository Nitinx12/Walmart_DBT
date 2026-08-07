/*
===============================================================================
Query Name : Market Basket Analysis Report
Layer      : Gold
Purpose    : Identify products that are frequently purchased together within
             the same order.

Description:
- Finds unique product pairs purchased in the same completed order.
- Removes duplicate and reverse product combinations.
- Calculates Basket Count, Support, Confidence, Lift, and Pair Rank.
- Identifies strong product associations for recommendation systems,
  cross-selling, and bundle analysis.

Source Tables:
    gold.fact_order_items
    gold.dim_orders
    gold.dim_products

Author      : Nitin
Created On  : 2026-08-06
===============================================================================
*/

WITH completed_orders AS (
    SELECT order_id
    FROM gold.dim_orders
    WHERE order_status = 'Completed'
),

product_pairs AS (
    SELECT
        oi1.product_id AS product_a_id,
        oi2.product_id AS product_b_id,
        COUNT(DISTINCT oi1.order_id) AS basket_count
    FROM gold.fact_order_items AS oi1
    INNER JOIN gold.fact_order_items AS oi2
        ON
            oi1.order_id = oi2.order_id
            AND oi1.product_id < oi2.product_id
    INNER JOIN completed_orders AS co
        ON oi1.order_id = co.order_id
    GROUP BY oi1.product_id, oi2.product_id
),

product_frequency AS (
    SELECT
        product_id,
        COUNT(DISTINCT order_id) AS product_orders
    FROM gold.fact_order_items
    GROUP BY
        product_id
),

total_orders AS (
    SELECT COUNT(DISTINCT order_id) AS total_orders
    FROM completed_orders
)

SELECT
    pp.product_a_id,
    p1.product_name AS product_a_name,
    pp.product_b_id,
    p2.product_name AS product_b_name,
    pp.basket_count,
    ROUND(
        pp.basket_count * 100.0
        / t.total_orders,
        2
    ) AS support_pct,
    ROUND(
        pp.basket_count * 100.0
        / pf1.product_orders,
        2
    ) AS confidence_pct,
    ROUND(
        (
            pp.basket_count::NUMERIC / t.total_orders
        )
        / (
            (pf1.product_orders::NUMERIC / t.total_orders)
            * (pf2.product_orders::NUMERIC / t.total_orders)
        ),
        2
    ) AS lift,
    DENSE_RANK() OVER (
        ORDER BY pp.basket_count DESC
    ) AS pair_rank
FROM product_pairs AS pp
INNER JOIN product_frequency AS pf1
    ON pp.product_a_id = pf1.product_id
INNER JOIN product_frequency AS pf2
    ON pp.product_b_id = pf2.product_id
INNER JOIN gold.dim_products AS p1
    ON pp.product_a_id = p1.product_id
INNER JOIN gold.dim_products AS p2
    ON pp.product_b_id = p2.product_id
CROSS JOIN total_orders AS t
ORDER BY
    basket_count DESC, pair_rank ASC;
