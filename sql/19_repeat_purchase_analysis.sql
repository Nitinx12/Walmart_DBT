/*
===============================================================================
Query Name : Repeat Purchase Analysis Report
Layer      : Gold
Purpose    : Analyze customer purchasing behavior by measuring repeat purchase
             patterns, purchase frequency, and average time between purchases.

Description:
- Calculates purchase history for each customer.
- Identifies first and last purchase dates.
- Calculates repeat orders and customer revenue.
- Measures the average number of days between consecutive purchases.
- Classifies customers based on purchase frequency.

Source Tables:
    gold.dim_customers
    gold.dim_orders
    gold.fact_order_items

Author      : Nitin
Created On  : 2026-08-06
===============================================================================
*/

WITH customer_orders AS (
    SELECT
        o.customer_id,
        o.order_id,
        o.order_timestamp::DATE AS order_date,
        c.first_name || ' ' || c.last_name AS customer_name,
        SUM(oi.line_amount) AS order_amount
    FROM gold.dim_orders AS o
    INNER JOIN gold.fact_order_items AS oi
        ON o.order_id = oi.order_id
    INNER JOIN gold.dim_customers AS c
        ON o.customer_id = c.customer_id
    WHERE o.order_status = 'Completed'
    GROUP BY
        o.customer_id,
        customer_name,
        o.order_id,
        order_date
),

purchase_gap AS (
    SELECT
        customer_id,
        customer_name,
        order_id,
        order_date,
        order_amount,
        LAG(order_date) OVER (
            PARTITION BY customer_id
            ORDER BY order_date
        ) AS previous_order_date
    FROM customer_orders
),

customer_summary AS (
    SELECT
        customer_id,
        customer_name,
        MIN(order_date) AS first_purchase_date,
        MAX(order_date) AS last_purchase_date,
        COUNT(order_id) AS total_orders,
        COUNT(order_id) - 1 AS repeat_orders,
        ROUND(SUM(order_amount), 2) AS total_revenue,
        ROUND(
            AVG(order_amount),
            2
        ) AS avg_order_value,
        ROUND(
            AVG(order_date - previous_order_date),
            2
        ) AS avg_days_between_purchases
    FROM purchase_gap
    GROUP BY
        customer_id,
        customer_name
)

SELECT
    customer_id,
    customer_name,
    first_purchase_date,
    last_purchase_date,
    total_orders,
    repeat_orders,
    total_revenue,
    avg_order_value,
    avg_days_between_purchases,
    CASE
        WHEN total_orders = 1
            THEN 'One-Time Buyer'
        WHEN total_orders BETWEEN 2 AND 5
            THEN 'Repeat Buyer'
        WHEN total_orders BETWEEN 6 AND 10
            THEN 'Frequent Buyer'
        ELSE 'Power Buyer'
    END AS customer_type
FROM customer_summary
ORDER BY
    total_orders DESC,
    total_revenue DESC;
