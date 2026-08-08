/*
===============================================================================
Query Name : Payment Method Performance Summary
Layer      : Gold
Purpose    : Generate a business summary of orders grouped by payment method,
             including an overall total row.

Description:
- Aggregates order-level metrics for each payment method.
- Adds an "ALL PAYMENT METHODS" summary row for overall comparison.
- Calculates the percentage contribution of each payment method to:
    • Total Orders
    • Total Revenue
- Returns key business metrics including:
    • Distinct Customers
    • Total Orders
    • Total Revenue
    • Average Order Value (AOV)
    • Minimum & Maximum Order Value
    • Inactive Order Count
- Includes payment methods with no associated orders using a LEFT JOIN.
- Displays the overall summary row at the bottom of the report.

Source Tables:
    gold.dim_payment_methods
    gold.dim_orders

Author      : Nitin
Created On  : 2026-08-03
===============================================================================
*/

WITH base_query AS (
    SELECT
        INITCAP(p.payment_method_name) AS payment_method_name,
        COUNT(DISTINCT o.customer_id) AS distinct_customers,
        COUNT(o.order_id) AS total_orders,
        SUM(o.total_amount) AS total_revenue,
        AVG(o.total_amount) AS avg_order_value,
        MIN(o.total_amount) AS min_order_value,
        MAX(o.total_amount) AS max_order_value,
        COUNT(*) FILTER (WHERE o.is_active = FALSE) AS inactive_order_count
    FROM gold.dim_payment_methods AS p
    LEFT JOIN gold.dim_orders AS o
        ON p.payment_method_id = o.payment_method_id
    GROUP BY p.payment_method_name
),

overall_agg AS MATERIALIZED (
    SELECT
        'ALL PAYMENT METHODS'::varchar AS payment_method_name,
        COUNT(DISTINCT customer_id) AS distinct_customers,
        COUNT(*) AS total_orders,
        SUM(total_amount) AS total_revenue,
        AVG(total_amount) AS avg_order_value,
        MIN(total_amount) AS min_order_value,
        MAX(total_amount) AS max_order_value,
        COUNT(*) FILTER (WHERE is_active = FALSE) AS inactive_order_count
    FROM gold.dim_orders
),

combined AS (
    SELECT
        *,
        0 AS sort_order
    FROM base_query

    UNION ALL

    SELECT
        *,
        1 AS sort_order
    FROM overall_agg
)

SELECT
    payment_method_name,
    distinct_customers,
    total_orders,
    min_order_value,
    max_order_value,
    inactive_order_count,
    ROUND(
        100.0 * total_orders
        / NULLIF((SELECT overall_agg.total_orders FROM overall_agg), 0),
        2
    ) AS pct_of_all_orders,
    ROUND(total_revenue, 2) AS total_revenue,
    ROUND(
        100.0 * total_revenue
        / NULLIF((SELECT overall_agg.total_revenue FROM overall_agg), 0),
        2
    ) AS pct_of_total_revenue,
    ROUND(avg_order_value, 2) AS avg_order_value
FROM combined
ORDER BY
    sort_order ASC,
    total_orders DESC;
