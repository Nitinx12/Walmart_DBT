# `sql/` — Gold-Layer Analysis

This folder does **not** build or load anything — that's dbt's job. Every script in `sql/` is a read-only analysis query (or a reusable function wrapping one) run **against the `gold.dim_*` / `gold.fact_*` tables that dbt already built**. Think of it as the analytics layer that sits on top of the warehouse: dbt owns bronze → silver → gold, and `sql/` is where that gold gets turned into the reports a business user actually asks for. It's meant to be run with `psql`, DBeaver, or any Postgres client once a dbt run has populated `gold` — no dbt or Airflow required to use it.

Every file is numbered in the order it's meant to be read/run, from foundational dimension-level checks up through the deeper multi-table business analyses.

## Folder layout & execution order

| # | File | Stage | What it does |
|---|---|---|---|
| 00 | `init_schema.sql` | Setup | Points the session at the `gold` schema dbt built (e.g. `search_path`), so every script below can reference `dim_customers` / `fact_order_items` without repeating `gold.` |
| 01 | `brands.sql` | Dimension analysis | Analysis query over `gold.dim_brands` |
| 02 | `category.sql` | Dimension analysis | Analysis query over `gold.dim_categories` |
| 03 | `payment_methods.sql` | Dimension analysis | Analysis query over the payment-method dimension |
| 04 | `fn_customer_report.sql` | Function | Dynamic, filterable customer activity report over `gold.dim_customers` / `gold.dim_orders` / `gold.fact_order_items` — [detailed below](#04-fn_customer_report--dynamic-customer-report) |
| 05 | `fn_product_report.sql` | Function | Product-side counterpart to 04 — parameterized product performance report over gold |
| 06 | `fn_sales_trend.sql` | Function | Date-bucketed sales trend function over `gold.fact_order_items` (likely daily/weekly/monthly grain parameter) |
| 07 | `trg_loaded.sql` | Trigger | Supports the gold-analysis layer (e.g. tracking when gold tables were last refreshed, so reports know their data is current) |
| 08 | `order_status_analysis.sql` | Report | Order breakdown by status, with an "ALL STATUSES" total row — [detailed below](#08-order_status_analysis--status-breakdown-with-totals) |
| 09 | `payment_method_analysis.sql` | Report | Same pattern as 08, sliced by payment method instead of status |
| 10 | `ranking_analysis.sql` | Report | Top-N ranking report (customers/products) via window functions |
| 11 | `kpi_summary_report.sql` | Report | Executive KPI dashboard — [detailed below](#11-kpi_summary_report--executive-kpi-dashboard) |
| 12 | `customer_segmentation.sql` | Report | Revenue-tier customer segmentation — [detailed below](#12-customer_segmentation--revenue-tier-segmentation) |
| 13 | `customer_cohort_analysis.sql` | Report | Cohorts customers by first-order period, tracks behavior over time |
| 14 | `customer_activity_summary.sql` | Report | Per-customer recency/frequency activity rollup |
| 15 | `pareto_revenue_analysis.sql` | Report | 80/20 revenue-contribution analysis (cumulative-revenue pattern, same family as 18) |
| 16 | `store_performance_summary.sql` | Report | Store/location-level performance rollup |
| 17 | `market_basket_analysis.sql` | Report | Product-affinity / "bought together" analysis |
| 18 | `abc_classification.sql` | Report | ABC inventory classification — [detailed below](#18-abc_classification--abc-inventory-classification) |
| 19 | `repeat_purchase_analysis.sql` | Report | Repeat vs. one-time purchaser breakdown |
| 20 | `no_sales_date_analysis.sql` | Report | Finds gaps — dates/periods with zero sales activity |


> Descriptions for files not walked through below (01–03, 05–07, 09–10, 13–17, 19–20) are inferred from filename + the conventions the other 5 files establish, not from reading their SQL directly. All of them, per the framing above, query gold — none of them create or load it.

Every report query below shares the same shape: **CTEs staged step-by-step, everything queried straight from `gold.*`, no fan-out joins, and column names written for a business audience** (`total_revenue`, `avg_order_value`) rather than raw table columns. That consistency is deliberate — it's what makes it safe to hand any of these queries straight to a BI tool.

---

## 04 · `fn_customer_report` — dynamic customer report

A single Postgres function that replaces a dozen hand-written "customer report with slightly different filters" queries. Every filter — customer, date range, status, geography, active flag — plus the sort column, sort direction, and row limit are all optional parameters. It builds and runs the query at runtime with `EXECUTE`.

```sql
CREATE OR REPLACE FUNCTION fn_customer_report(
    p_schema                     TEXT       DEFAULT 'public',
    p_customer_id                INTEGER    DEFAULT NULL,
    p_start_date                 DATE       DEFAULT NULL,
    p_end_date                   DATE       DEFAULT NULL,
    p_order_status               VARCHAR    DEFAULT NULL,
    p_is_active                  BOOLEAN    DEFAULT NULL,
    p_include_inactive_orders    BOOLEAN    DEFAULT FALSE,
    p_country                    VARCHAR    DEFAULT NULL,
    p_province                   VARCHAR    DEFAULT NULL,
    p_city                       VARCHAR    DEFAULT NULL,
    p_sort_by                    TEXT       DEFAULT 'total_spent',
    p_sort_direction             TEXT       DEFAULT 'DESC',
    p_limit                      INTEGER    DEFAULT NULL
)
RETURNS TABLE (
    customer_id integer, customer_name varchar, phone text, email varchar,
    city varchar, province varchar, country varchar, is_active boolean,
    total_orders integer, total_items bigint, total_spent numeric(14,2),
    total_line_item_amount numeric(14,2), amount_variance numeric(14,2),
    avg_order_value numeric(14,2), first_order_date timestamp,
    last_order_date timestamp, days_since_last_order integer
)
LANGUAGE plpgsql AS $function$
-- builds v_order_where / v_customer_where fragments from whichever
-- parameters were passed, whitelists p_sort_by / p_sort_direction against
-- a CASE expression, then EXECUTEs a query with two CTEs:
--   order_agg  -> order-header grain aggregates (no fan-out risk)
--   item_agg   -> order-item grain aggregates, joined back through orders
-- and LEFT JOINs both onto dim_customers.
$function$;
```

**Worth calling out:**

- **Injection safety despite dynamic SQL.** `p_schema` is interpolated with `%I` (identifier quoting), every filter value goes through `%L` (literal quoting/escaping), and `p_sort_by`/`p_sort_direction` — the two values that *can't* go through `%L` because they're column/keyword names, not literals — are resolved against a hard-coded `CASE` whitelist first. Anything that doesn't match a known value raises an exception instead of reaching the query.
- **Two independent revenue numbers, on purpose.** `total_spent` comes from `dim_orders.total_amount` (order-header grain — safe to sum, no join fan-out). `total_line_item_amount` comes independently from `fact_order_items.line_amount`. The function doesn't assume these agree; it returns both plus `amount_variance` so a mismatch (tax/shipping/discount not captured at line level, or a data-quality bug) surfaces instead of getting silently averaged away.
- **Schema-agnostic.** Table names are built from `p_schema` at call time, so the same function runs against `gold`, a test schema, or any medallion layer without editing the function body.
- **Self-diagnosing on failure.** The `EXCEPTION WHEN OTHERS` block re-raises with the generated SQL string attached, so a failure tells you exactly what query ran, not just that something broke.

```sql
SELECT * FROM fn_customer_report(p_schema := 'gold', p_is_active := TRUE, p_limit := 10);
```

---

## 08 · `order_status_analysis` — status breakdown with totals

Answers "how are orders distributed across statuses, and how does each status compare to the whole book?" in one result set that includes its own total row.

```sql
WITH status_agg AS (
    SELECT order_status, COUNT(*) AS order_count,
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
    SELECT 'ALL STATUSES'::varchar AS order_status, COUNT(*) AS order_count, ...
    FROM gold.dim_orders
),
combined AS (
    SELECT *, 0 AS sort_order FROM status_agg
    UNION ALL
    SELECT *, 1 AS sort_order FROM overall_agg
)
SELECT order_status, order_count,
       ROUND(100.0 * order_count / NULLIF((SELECT order_count FROM overall_agg), 0), 2) AS pct_of_all_orders,
       ROUND(100.0 * total_revenue / NULLIF((SELECT total_revenue FROM overall_agg), 0), 2) AS pct_of_total_revenue,
       ...
FROM combined
ORDER BY sort_order, order_count DESC;
```

**Worth calling out:**

- **`AS MATERIALIZED`** forces Postgres to compute `overall_agg` once rather than inline it into the two scalar subqueries that reference it — those subqueries would otherwise risk re-scanning `dim_orders` for the percentage calculation.
- **`UNION ALL` with a `sort_order` tiebreaker** is the pattern used to pin a synthetic "grand total" row to the bottom of a grouped report without a second query or app-side stitching.
- **`COUNT(*) FILTER (WHERE ...)`** is used instead of a `CASE WHEN` inside `SUM` — same result, clearer intent for a boolean-flag count.

---

## 11 · `kpi_summary_report` — executive KPI dashboard

A single flat list of headline metrics — customers, products, orders, revenue — shaped for a BI card/tile layout rather than a table of rows and columns.

```sql
WITH customer_base AS (
    SELECT 'Total Customers' AS measure_name, COUNT(DISTINCT customer_id) AS measure_value
    FROM gold.dim_customers
),
product_base AS (
    SELECT 'Total Products', COUNT(DISTINCT product_id) FROM gold.dim_products
),
order_base AS (
    SELECT 'Total Orders', COUNT(DISTINCT order_id) FROM gold.dim_orders
),
-- ...order_customer_base, quantity_sold_base, avg_quantity_base,
--    avg_price_base, total_sales_base, avg_sales_base follow the same shape
SELECT * FROM customer_base
UNION ALL SELECT * FROM product_base
UNION ALL SELECT * FROM order_base
UNION ALL SELECT * FROM order_customer_base
UNION ALL SELECT * FROM quantity_sold_base
UNION ALL SELECT * FROM avg_quantity_base
UNION ALL SELECT * FROM avg_price_base
UNION ALL SELECT * FROM total_sales_base
UNION ALL SELECT * FROM avg_sales_base;
```

**Worth calling out:**

- **EAV-style output** (`measure_name`, `measure_value`) instead of one-column-per-metric is a deliberate trade: it's harder to read raw in `psql`, but it's the shape Power BI / Tableau want for a card visual, and adding a tenth KPI means adding a tenth CTE + `UNION ALL` line — no schema change downstream.
- **One CTE per metric** keeps each calculation isolated and independently testable, at the cost of scanning some tables more than once. For an executive summary run on demand (not in a hot path), that trade favors readability.

---

## 12 · `customer_segmentation` — revenue-tier segmentation

Buckets every customer into Platinum / Gold / Silver / Bronze by lifetime revenue, then rolls each tier up into segment-level KPIs plus its share of the whole business.

```sql
WITH customer_base AS (
    SELECT O.customer_id,
           SUM(OI.line_amount) AS total_revenue,
           COUNT(DISTINCT O.order_id) AS total_orders,
           ROUND(SUM(OI.line_amount) / NULLIF(COUNT(DISTINCT O.order_id), 0), 2) AS avg_order_value
    FROM gold.dim_orders AS O
    INNER JOIN gold.fact_order_items AS OI ON O.order_id = OI.order_id
    GROUP BY O.customer_id
),
segment_base AS (
    SELECT *,
        CASE
            WHEN total_revenue >= 10000 THEN 'Platinum'
            WHEN total_revenue >= 5000  THEN 'Gold'
            WHEN total_revenue >= 1000  THEN 'Silver'
            ELSE 'Bronze'
        END AS customer_segment
    FROM customer_base
),
summary_base AS (
    SELECT customer_segment, COUNT(customer_id) AS total_customers,
           ROUND(SUM(total_revenue), 2) AS total_revenue,
           ROUND(AVG(total_revenue), 2) AS avg_revenue_per_customer,
           SUM(total_orders) AS total_orders,
           ROUND(AVG(avg_order_value), 2) AS avg_order_value
    FROM segment_base
    GROUP BY customer_segment
)
SELECT customer_segment, total_customers, total_revenue, avg_revenue_per_customer,
       total_orders, avg_order_value,
       ROUND(total_revenue * 100.0 / SUM(total_revenue) OVER (), 2) AS revenue_percentage,
       ROUND(total_customers * 100.0 / SUM(total_customers) OVER (), 2) AS customer_percentage
FROM summary_base
ORDER BY CASE customer_segment
    WHEN 'Platinum' THEN 1 WHEN 'Gold' THEN 2 WHEN 'Silver' THEN 3 ELSE 4 END;
```

**Worth calling out:**

- **Three-stage CTE pipeline**: compute per-customer facts → label each customer → aggregate by label. Splitting the `CASE` (labeling) from the `GROUP BY` (aggregating) means the threshold logic lives in exactly one place and reads top-to-bottom.
- **`SUM(...) OVER ()`** (empty window — no `PARTITION BY`) computes each segment's share of the *entire* table's total in the same pass, without a self-join or a second query against `summary_base`.
- **Explicit `CASE`-based `ORDER BY`** enforces business priority order (Platinum first) instead of alphabetical or revenue order, which matters for how this reads on a dashboard.

---

## 18 · `abc_classification` — ABC inventory classification

Classic inventory-prioritization analysis: rank products by revenue, walk a cumulative-revenue running total down the ranked list, and split into A (top 80% of revenue), B (next 15%), C (remaining 5%).

```sql
WITH product_base AS (
    SELECT P.product_id, P.product_name, B.brand_name, C.category_name,
           COUNT(DISTINCT OI.order_id) AS total_orders,
           SUM(OI.quantity) AS quantity_sold,
           SUM(OI.line_amount) AS total_revenue,
           DENSE_RANK() OVER (ORDER BY SUM(OI.line_amount) DESC, P.product_id ASC) AS revenue_rank
    FROM gold.fact_order_items AS OI
    INNER JOIN gold.dim_products AS P ON P.product_id = OI.product_id
    INNER JOIN gold.dim_brands AS B ON B.brand_id = P.brand_id
    INNER JOIN gold.dim_categories AS C ON C.category_id = P.category_id
    GROUP BY P.product_id, P.product_name, B.brand_name, C.category_name
),
grand_total AS (
    SELECT SUM(total_revenue) AS grand_revenue FROM product_base
),
analysis_base AS (
    SELECT pb.*,
           ROUND(pb.total_revenue * 100.0 / gt.grand_revenue, 2) AS revenue_pct,
           SUM(pb.total_revenue) OVER (
               ORDER BY pb.total_revenue DESC, pb.product_id
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
           ) AS cumulative_revenue,
           ROUND(SUM(pb.total_revenue) OVER (
               ORDER BY pb.total_revenue DESC, pb.product_id
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
           ) * 100.0 / gt.grand_revenue, 2) AS cumulative_pct
    FROM product_base AS pb
    CROSS JOIN grand_total AS gt
)
SELECT *,
    CASE WHEN cumulative_pct <= 80 THEN 'A'
         WHEN cumulative_pct <= 95 THEN 'B'
         ELSE 'C' END AS abc_category
FROM analysis_base
ORDER BY total_revenue DESC, product_id;
```

**Worth calling out:**

- **`ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`** is the running-total window frame — each row's `cumulative_revenue` is the sum of every row from the top of the revenue-sorted list down to itself. This *is* the ABC algorithm; everything else in the query is staging for it.
- **Deterministic tiebreaking.** Both the `DENSE_RANK()` and the running-total window order by `product_id` after `total_revenue`, so products with identical revenue always land in the same order on every run — important for a report whose classification (A/B/C) depends on cumulative position.
- **`CROSS JOIN grand_total`** is a one-row-table broadcast join — the standard way to make a single scalar (the grand total) available to every row without a correlated subquery per row.

---

## Design patterns shared across the folder

- **CTE-staged, not nested-subquery.** Every report reads top-to-bottom as a pipeline: raw facts → derived metrics → business labels → final shape.
- **Everything reads from `gold.*` only.** No script in this folder reaches back into bronze or silver — that boundary is dbt's job; `sql/` assumes gold is already correct.
- **Business-readable output columns.** Column names in the final `SELECT` (`revenue_percentage`, `abc_category`, `days_since_last_order`) are written for whoever consumes the report, not copied from source columns.
- **Header comment block on every file** — Query Name, Layer, Purpose, Description, Source Tables, Author, Created On — so any script is self-documenting without opening the docs.
