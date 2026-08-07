/*
===============================================================================
Query Name : Customer Activity Summary Report
Layer      : Gold
Purpose    : Summarize customer activity using SQL Set Operators.

Description:
- Identifies Loyal, New, and Lost customers.
- Creates the Active customer population.
- Returns the number of customers in each segment.
- Demonstrates the use of:
    • INTERSECT
    • EXCEPT
    • UNION
    • UNION ALL

Source Table:
    gold.dim_orders

Author      : Nitin
Created On  : 2026-08-06
===============================================================================
*/

WITH orders_2026 AS (
    SELECT DISTINCT customer_id
    FROM gold.dim_orders
    WHERE EXTRACT(YEAR FROM order_timestamp) = 2026
),

orders_2027 AS (
    SELECT DISTINCT customer_id
    FROM gold.dim_orders
    WHERE EXTRACT(YEAR FROM order_timestamp) = 2027
),

loyal_customers AS (
    SELECT customer_id
    FROM orders_2026

    INTERSECT

    SELECT customer_id
    FROM orders_2027
),

new_customers AS (
    SELECT customer_id FROM orders_2027

    EXCEPT

    SELECT customer_id FROM orders_2026
),

lost_customers AS (
    SELECT customer_id FROM orders_2026

    EXCEPT

    SELECT customer_id FROM orders_2027
),

active_customers AS (
    SELECT customer_id FROM loyal_customers

    UNION

    SELECT customer_id FROM new_customers
)

SELECT
    'Total Customers (2026)' AS customer_segment,
    COUNT(*) AS total_customers
FROM orders_2026

UNION ALL

SELECT
    'Total Customers (2027)' AS customer_segment,
    COUNT(*) AS total_customers
FROM orders_2027

UNION ALL

SELECT
    'Active Customers' AS customer_segment,
    COUNT(*) AS total_customers
FROM active_customers

UNION ALL

SELECT
    'Loyal Customers' AS customer_segment,
    COUNT(*) AS total_customers
FROM loyal_customers

UNION ALL

SELECT
    'New Customers' AS customer_segment,
    COUNT(*) AS total_customers
FROM new_customers

UNION ALL

SELECT
    'Lost Customers' AS customer_segment,
    COUNT(*) AS total_customers
FROM lost_customers;