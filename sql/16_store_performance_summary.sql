/*
===============================================================================
Query Name : Store Performance Summary Report
Layer      : Gold
Purpose    : Generate an executive summary of store performance by analyzing
             sales, customers, products, and operational KPIs.

Description:
- Aggregates order and sales metrics for each store.
- Calculates revenue contribution and revenue ranking.
- Categorizes stores into performance tiers based on total revenue.
- Returns key business metrics including:
    • Total Orders
    • Completed & Cancelled Orders
    • Distinct Customers
    • Distinct Products Sold
    • Total Revenue
    • Average Order Value (AOV)
    • Average Unit Price
    • Total Quantity Sold
    • Average Quantity per Order
    • Earliest & Latest Order Dates
    • Revenue Contribution (%)
    • Revenue Rank
    • Performance Category

Source Tables:
    gold.dim_stores
    gold.dim_orders
    gold.fact_order_items

Author      : Nitin
Created On  : 2026-08-06
===============================================================================
*/

WITH store_base AS (
    SELECT
        S.store_id,
        S.store_name,
        S.city,
        COUNT(DISTINCT O.order_id)                                  AS total_orders,
        COUNT(DISTINCT O.order_id)
            FILTER (WHERE O.order_status = 'Completed')             AS completed_orders,
        COUNT(DISTINCT O.order_id)
            FILTER (WHERE O.order_status = 'Cancelled')             AS cancelled_orders,
        COUNT(DISTINCT O.customer_id)                               AS distinct_customers,
        COUNT(DISTINCT OI.product_id)                               AS distinct_products_sold,
        ROUND(SUM(OI.line_amount), 2)                               AS total_revenue,
        ROUND(
            SUM(OI.line_amount) /
            NULLIF(COUNT(DISTINCT O.order_id), 0),
            2
        )                                                           AS avg_order_value,
        ROUND(AVG(OI.unit_price), 2)                                AS avg_unit_price,
        SUM(OI.quantity)                                            AS total_quantity_sold,
        ROUND(
            SUM(OI.quantity)::NUMERIC /
            NULLIF(COUNT(DISTINCT O.order_id), 0),
            2
        )                                                           AS avg_quantity_per_order,
        MIN(O.order_timestamp)::DATE                                AS earliest_order_date,
        MAX(O.order_timestamp)::DATE                                AS latest_order_date
    FROM gold.dim_stores AS S
    INNER JOIN gold.dim_orders AS O
        ON S.store_id = O.store_id
    INNER JOIN gold.fact_order_items AS OI
        ON O.order_id = OI.order_id
    WHERE S.is_active = TRUE
    GROUP BY
        S.store_id,
        S.store_name,
        S.city
)
SELECT
    store_id,
    store_name,
    city,
    total_orders,
    completed_orders,
    cancelled_orders,
    distinct_customers,
    distinct_products_sold,
    total_revenue,
    avg_order_value,
    avg_unit_price,
    total_quantity_sold,
    avg_quantity_per_order,
    earliest_order_date,
    latest_order_date,
    ROUND(
        total_revenue * 100.0 /
        SUM(total_revenue) OVER (),
        2
    ) AS revenue_percentage,
    DENSE_RANK() OVER (
        ORDER BY total_revenue DESC
    ) AS revenue_rank,
    CASE
        WHEN total_revenue >= 1000000 THEN 'High Performer'
        WHEN total_revenue >= 500000 THEN 'Medium Performer'
        ELSE 'Low Performer'
    END AS performance_category
FROM store_base
ORDER BY total_revenue DESC;