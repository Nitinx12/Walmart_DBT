# Category Revenue Analysis Report

**Layer:** Gold | **Database:** PostgreSQL | **Source Script:** `02_category.sql` | **Author:** Nitin
**Report Date:** 2026-08-03

---

## 1. Purpose

This report explains how revenue is distributed across product categories, walks through the SQL logic that produces the numbers, visualizes the distribution, and calls out what the pattern means for the business.

Note on scope: the source query is a **single-period snapshot** (all-time totals as of extraction), not a time series. What follows is a *distribution* analysis — how revenue is spread across categories right now — not a month-over-month or year-over-year trend. Section 6 covers what to add if true time-based trending is the goal.

---

## 2. SQL Query Breakdown

```sql
WITH cate_base AS(
    SELECT
        C.category_id,
        C.category_name,
        SUM(OI.line_amount) AS total_amount
    FROM gold.dim_categories AS C
    LEFT JOIN gold.dim_products AS P
        ON P.category_id = C.category_id
    LEFT JOIN gold.fact_order_items AS OI
        ON OI.product_id = P.product_id
    GROUP BY
        C.category_id,
        C.category_name
),
grand_total AS(
    SELECT SUM(total_amount) AS grand_revenue
    FROM cate_base
)
SELECT
    C.category_name,
    C.total_amount,
    ROUND(C.total_amount / GT.grand_revenue * 100,2) AS pct_of_total
FROM cate_base AS C
CROSS JOIN grand_total AS GT
```

| Step | What it does | Why it matters |
|---|---|---|
| `cate_base` CTE | Walks `dim_categories → dim_products → fact_order_items` and sums `line_amount` per category | Establishes the revenue base at the correct grain (one row per category) before any ratio math happens |
| `LEFT JOIN` (both hops) | Keeps every category even if it has no products, and every product even if it has no order items | Categories with zero sales still appear with `total_amount = NULL`, so the report doesn't silently hide dead categories. An `INNER JOIN` here would quietly drop them |
| `grand_total` CTE | Sums `total_amount` across all categories into a single-row total | Isolates the "whole" the percentages will be measured against, computed once rather than recomputed per row |
| `CROSS JOIN` in the final `SELECT` | Broadcasts the single grand-total row onto every category row | Standard pattern for "% of total" when you don't want to use a window function — every category row gets access to the same denominator |
| `ROUND(..., 2)` | Rounds the percentage to 2 decimals | Keeps the output presentation-ready without extra formatting downstream |

**A note on an alternative approach:** the same result could be produced with a single `SUM(total_amount) OVER ()` window function instead of a second CTE + `CROSS JOIN`. Both are correct; the CTE approach here is slightly more explicit and easier to debug, at the cost of one extra join. Worth knowing both patterns since interviewers sometimes ask which you'd pick and why.

**Data quality check:** with the current data, no category returned `NULL`, meaning every category has at least one product with at least one order item — the `LEFT JOIN`s aren't currently doing defensive work, but they're the correct choice for a report that should stay accurate if that changes.

---

## 3. Output Data

| Category | Revenue (₹) | % of Total |
|---|---:|---:|
| Electronics | 3,364,618.80 | 17.76% |
| Clothing | 3,323,388.06 | 17.54% |
| Grocery | 3,290,031.88 | 17.36% |
| Sports | 3,202,731.59 | 16.90% |
| Toys | 3,050,311.04 | 16.10% |
| Home | 2,716,715.19 | 14.34% |
| **Total** | **18,947,796.56** | **100.00%** |

---

## 4. Charts

### Revenue by Category
<img width="1500" height="900" alt="image" src="https://github.com/user-attachments/assets/880f2fc8-d386-4d97-852b-7038d2fcd840" />

### Revenue Share by Category
<img width="1150" height="817" alt="image" src="https://github.com/user-attachments/assets/a570a9a8-8e95-4e09-9ad0-d4fe00292be5" />

*Charts generated with `matplotlib` + `seaborn` (`whitegrid` theme, `crest` palette).*

---

## 5. Distribution Analysis

- **Five of six categories are tightly clustered.** Electronics, Clothing, Grocery, Sports, and Toys all fall within a **1.66 percentage-point band** (16.10%–17.76%). No single category dominates the mix.
- **Home is the clear outlier.** At 14.34%, it sits **3.42 points below Electronics** (the leader) and is the only category below 16%. In absolute terms, Home trails the average of the other five categories (₹3,246,216) by roughly **₹530,000**.
- **No category is negligible.** Every category contributes at least 14% of total revenue — there's no long tail of underperforming categories dragging the average down, which is generally a healthy sign for a retail mix.

---

## 6. Key Takeaways

1. **Electronics is the current revenue leader** at 17.76%, but only marginally ahead of Clothing (17.54%) and Grocery (17.36%) — the top three are effectively neck-and-neck rather than one category pulling away.
2. **Home is the one category worth investigating.** A ~3.4-point gap from the leader is large enough to be a real signal, not noise. This query alone can't say *why* — it could be fewer SKUs in the category, lower average order value, lower unit volume, or a pricing issue. The next diagnostic step would be joining in `fact_order_items` quantity and `dim_products` count per category to see which lever is driving it.
3. **The category mix is diversified**, which is generally a lower-risk position than one dominated by a single category — no category exceeds ~18% of revenue, so a slump in any one category has bounded impact on the total.
4. **This is a snapshot, not a trend.** To actually answer "is Home *declining*" (versus "is Home *lower*"), the query needs a date dimension and a `GROUP BY` on month/quarter, plus a period-over-period comparison (e.g., `LAG()` over month, similar to the pattern used in the LRDB sales reporting functions). Flagging this now so it doesn't get mistaken for time-series trend analysis later.

---

## 7. Why This Matters

- **Inventory & buying decisions:** category revenue share is a direct input into how much shelf space, warehouse capacity, and supplier purchase volume each category should get. Home's underperformance is a candidate for a buying or assortment review before more capital gets allocated to it.
- **Marketing spend allocation:** a balanced mix (as seen in categories 2–5) suggests marketing budget doesn't need to be aggressively skewed toward one category to protect revenue — but Home may warrant a targeted push to close the gap.
- **Concentration risk:** no category above ~18% means the business isn't overexposed to a single category's demand shocks (seasonality, supply issues, competitor pricing). That's a useful data point for anyone assessing revenue stability.
- **Baseline for future trend work:** this snapshot is the reference point. Once the same query is extended with a time dimension, this report becomes the "starting line" to measure category growth or decline against.

---

## 8. Files

| File | Description |
|---|---|
| `02_category.sql` | Source query (unchanged) |
| `category_revenue_bar.png` | Horizontal bar chart, revenue by category |
| `category_revenue_share.png` | Donut chart, % share of total revenue |
| `category_report.md` | This report |
