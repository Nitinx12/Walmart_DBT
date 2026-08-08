/*
===============================================================================
Query Name : Order Status Summary Report
Layer      : Gold
Purpose    : Generate a business summary of orders grouped by order_status,
             including an overall total row.

Description:
- Aggregates order-level metrics for each order_status.
- Adds an "ALL STATUSES" summary row for overall comparison.
- Calculates the percentage contribution of each status to:
    • Total Orders
    • Total Revenue
- Returns key business metrics including:
    • Order Count
    • Distinct Customers
    • Total Revenue
    • Average Order Value (AOV)
    • Minimum & Maximum Order Value
    • Earliest & Latest Order Dates
    • Inactive Order Count
- Displays the overall summary row at the bottom of the report.

Source Table:
    gold.dim_orders

Author      : Nitin
Created On  : 2026-08-03
===============================================================================
*/

-- Per-status aggregates: one row per distinct order_status
WITH status_agg AS (
    SELECT
        order_status,
        COUNT(*) AS order_count,
        COUNT(DISTINCT customer_id) AS distinct_customers,
        SUM(total_amount) AS total_revenue,
        AVG(total_amount) AS avg_order_value,
        MIN(total_amount) AS min_order_value,
        MAX(total_amount) AS max_order_value,
        MIN(order_timestamp)::date AS earliest_order_date,
        MAX(order_timestamp)::date AS latest_order_date,
        COUNT(*) FILTER (WHERE is_active = FALSE) AS inactive_order_count
    FROM gold.dim_orders
    GROUP BY order_status
),

overall_agg AS MATERIALIZED (
    SELECT
        'ALL STATUSES'::varchar AS order_status,
        COUNT(*) AS order_count,
        COUNT(DISTINCT customer_id) AS distinct_customers,
        SUM(total_amount) AS total_revenue,
        AVG(total_amount) AS avg_order_value,
        MIN(total_amount) AS min_order_value,
        MAX(total_amount) AS max_order_value,
        MIN(order_timestamp)::date AS earliest_order_date,
        MAX(order_timestamp)::date AS latest_order_date,
        COUNT(*) FILTER (WHERE is_active = FALSE) AS inactive_order_count
    FROM gold.dim_orders
),

combined AS (
    SELECT
        *,
        0 AS sort_order
    FROM status_agg
    UNION ALL
    SELECT
        *,
        1 AS sort_order
    FROM overall_agg
)

SELECT
    order_status,
    order_count,
    distinct_customers,
    min_order_value,
    max_order_value,
    earliest_order_date,
    latest_order_date,
    inactive_order_count,
    ROUND(
        100.0 * order_count
        / NULLIF((SELECT overall_agg.order_count FROM overall_agg), 0), 2
    ) AS pct_of_all_orders,
    ROUND(total_revenue, 2) AS total_revenue,
    ROUND(
        100.0 * total_revenue
        / NULLIF((SELECT overall_agg.total_revenue FROM overall_agg), 0), 2
    ) AS pct_of_total_revenue,
    ROUND(avg_order_value, 2) AS avg_order_value
FROM combined
ORDER BY sort_order ASC, order_count DESC;
