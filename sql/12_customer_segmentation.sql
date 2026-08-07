/*
===============================================================================
Query Name : Customer Segmentation Report
Layer      : Gold
Purpose    : Segment customers based on their lifetime revenue and generate
             key business metrics for each customer segment.

Description:
- Calculates lifetime revenue and order metrics for every customer.
- Segments customers into Platinum, Gold, Silver, and Bronze based on
  lifetime revenue.
- Returns summary metrics for each segment including:
    • Number of Customers
    • Total Revenue
    • Average Revenue per Customer
    • Total Orders
    • Average Order Value (AOV)
    • Revenue Contribution (%)
    • Customer Contribution (%)
- Displays customer segments in business priority order.

Source Tables:
    gold.dim_orders
    gold.fact_order_items

Author      : Nitin
Created On  : 2026-08-06
===============================================================================
*/

WITH customer_base AS (
    SELECT
        o.customer_id,
        SUM(oi.line_amount) AS total_revenue,
        COUNT(DISTINCT o.order_id) AS total_orders,
        ROUND(
            SUM(oi.line_amount)
            / NULLIF(COUNT(DISTINCT o.order_id), 0),
            2
        ) AS avg_order_value
    FROM gold.dim_orders AS o
    INNER JOIN gold.fact_order_items AS oi
        ON o.order_id = oi.order_id
    GROUP BY
        o.customer_id
),

segment_base AS (
    SELECT
        customer_id,
        total_revenue,
        total_orders,
        avg_order_value,
        CASE
            WHEN total_revenue >= 10000 THEN 'Platinum'
            WHEN total_revenue >= 5000 THEN 'Gold'
            WHEN total_revenue >= 1000 THEN 'Silver'
            ELSE 'Bronze'
        END AS customer_segment
    FROM customer_base
),

summary_base AS (
    SELECT
        customer_segment,
        COUNT(customer_id) AS total_customers,
        ROUND(SUM(total_revenue), 2) AS total_revenue,
        ROUND(AVG(total_revenue), 2) AS avg_revenue_per_customer,
        SUM(total_orders) AS total_orders,
        ROUND(AVG(avg_order_value), 2) AS avg_order_value
    FROM segment_base
    GROUP BY
        customer_segment
)

SELECT
    customer_segment,
    total_customers,
    total_revenue,
    avg_revenue_per_customer,
    total_orders,
    avg_order_value,
    ROUND(
        total_revenue * 100.0
        / SUM(total_revenue) OVER (),
        2
    ) AS revenue_percentage,
    ROUND(
        total_customers * 100.0
        / SUM(total_customers) OVER (),
        2
    ) AS customer_percentage
FROM summary_base
ORDER BY
    CASE customer_segment
        WHEN 'Platinum' THEN 1
        WHEN 'Gold' THEN 2
        WHEN 'Silver' THEN 3
        WHEN 'Bronze' THEN 4
    END;
