/*
===============================================================================
Query Name : Pareto (80/20) Customer Revenue Analysis
Layer      : Gold
Purpose    : Identify the customers responsible for generating approximately
             80% of total revenue using the Pareto Principle.

Description:
- Aggregates lifetime revenue for each customer from completed orders.
- Ranks customers in descending order of total revenue.
- Calculates each customer's percentage contribution to total revenue.
- Computes cumulative revenue and cumulative revenue percentage.
- Classifies customers into:
    • Top 80% Revenue
    • Remaining 20%
- Helps identify high-value customers for targeted marketing,
  retention strategies, and revenue optimization.

Key Metrics:
    • Total Revenue
    • Revenue Rank
    • Revenue Contribution (%)
    • Cumulative Revenue
    • Cumulative Revenue (%)
    • Pareto Segment

Source Tables:
    gold.dim_orders
    gold.fact_order_items

Author      : Nitin
Created On  : 2026-08-06
===============================================================================
*/

WITH base_query AS(
    SELECT
        o.customer_id,
        SUM(oi.line_amount) AS total_revenue,
        DENSE_RANK() OVER(
            ORDER BY SUM(oi.line_amount) DESC
        ) AS revenue_rank
    FROM gold.dim_orders AS o
    INNER JOIN gold.fact_order_items AS oi
        ON oi.order_id = o.order_id
    WHERE o.order_status = 'Completed'
    GROUP BY o.customer_id
),
grand_total AS(
    SELECT SUM(total_revenue) AS grand_revenue
    FROM base_query
),
cumm_based AS(
    SELECT
        bq.customer_id,
        bq.total_revenue,
        bq.revenue_rank,
        ROUND(
            SUM(bq.total_revenue) OVER(
            ORDER BY bq.total_revenue DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ),2)                                        AS cumulative_revenue,
        ROUND(
            SUM(bq.total_revenue) OVER(
            ORDER BY bq.total_revenue DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) * 100 / gr.grand_revenue,2)               AS cumulative_pct
        
    FROM base_query AS bq
    CROSS JOIN grand_total AS gr
)
SELECT
    customer_id,
    total_revenue,
    revenue_rank,
    cumulative_revenue,
    cumulative_pct,
    CASE
        WHEN cumulative_pct <= 80.00
            THEN 'Top 80% Revenue'
        ELSE 'Remaining 20%'
    END AS pareto_segment
FROM cumm_based


