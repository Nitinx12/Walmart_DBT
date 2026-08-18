/*
===============================================================================
Query Name : Executive KPI Summary Report
Layer      : Gold
Purpose    : Generate a consolidated executive dashboard containing key
             business KPIs for customers, products, orders, and sales.

Description:
- Aggregates high-level business metrics into a single KPI report.
- Uses Common Table Expressions (CTEs) to calculate each metric independently.
- Combines all KPIs into a unified result using UNION ALL.
- Returns executive-level metrics including:
    • Total Customers
    • Total Products
    • Total Orders
    • Customers with Orders
    • Total Quantity Sold
    • Average Quantity Sold
    • Average Unit Price
    • Total Sales Revenue
    • Average Sales per Order Line
- Designed for Power BI, Tableau, Databricks SQL Dashboards, and executive
  reporting.

Source Tables:
    gold.dim_customers
    gold.dim_products
    gold.dim_orders
    gold.fact_order_items

Author      : Nitin
Created On  : 2026-08-06
===============================================================================
*/

WITH customer_base AS (
    SELECT
        'Total Customers' AS measure_name,
        COUNT(DISTINCT customer_id) AS measure_value
    FROM gold.dim_customers
),

product_base AS (
    SELECT
        'Total Products' AS measure_name,
        COUNT(DISTINCT product_id) AS measure_value
    FROM gold.dim_products
),

order_base AS (
    SELECT
        'Total Orders' AS measure_name,
        COUNT(DISTINCT order_id) AS measure_value
    FROM gold.dim_orders
),

order_customer_base AS (
    SELECT
        'Total Order Customers' AS measure_name,
        COUNT(DISTINCT customer_id) AS measure_value
    FROM gold.dim_orders
),

quantity_sold_base AS (
    SELECT
        'Quantity Sold' AS measure_name,
        SUM(quantity) AS measure_value
    FROM gold.fact_order_items
),

avg_quantity_base AS (
    SELECT
        'Average Quantity Sold' AS measure_name,
        ROUND(AVG(quantity), 2) AS measure_value
    FROM gold.fact_order_items
),

avg_price_base AS (
    SELECT
        'Average Unit Price' AS measure_name,
        ROUND(AVG(unit_price), 2) AS measure_value
    FROM gold.fact_order_items
),

total_sales_base AS (
    SELECT
        'Total Sales' AS measure_name,
        ROUND(SUM(line_amount), 2) AS measure_value
    FROM gold.fact_order_items
),

avg_sales_base AS (
    SELECT
        'Average Sales Per Line' AS measure_name,
        ROUND(AVG(line_amount), 2) AS measure_value
    FROM gold.fact_order_items
)

SELECT * FROM customer_base
UNION ALL
SELECT * FROM product_base
UNION ALL
SELECT * FROM order_base
UNION ALL
SELECT * FROM order_customer_base
UNION ALL
SELECT * FROM quantity_sold_base
UNION ALL
SELECT * FROM avg_quantity_base
UNION ALL
SELECT * FROM avg_price_base
UNION ALL
SELECT * FROM total_sales_base
UNION ALL
SELECT * FROM avg_sales_base;
