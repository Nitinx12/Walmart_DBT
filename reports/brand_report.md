# Brand Revenue Analysis

**Layer:** Gold &nbsp;|&nbsp; **Database:** PostgreSQL &nbsp;|&nbsp; **Author:** Nitin &nbsp;|&nbsp; **Date:** 2026-08-02

## 1. Objective

This report analyzes revenue contribution by brand, based on the output of the `brand_base` / `grand_revenue` CTEs in `brands.sql`. The query aggregates `line_amount` from `fact_order_items` for each brand via `dim_products`, then expresses each brand's total against grand revenue as a percentage share.

## 2. Summary Metrics

| Metric | Value |
|---|---|
| Brands analyzed | 7 |
| Combined revenue | $18,947,796.56 |
| Top brand | Apple (15.75%) |
| Lowest brand | Nestle (12.56%) |
| Top-3 combined share | 45.65% |
| Spread (top − bottom) | 3.19 pts |
| Average share per brand | 14.29% |

## 3. Revenue by Brand

<img width="1800" height="1100" alt="image" src="https://github.com/user-attachments/assets/79a758ca-17e6-40b1-9d2d-1aa820a59036" />


Apple leads with **$2,984,932.71** (15.75% of total revenue), narrowly ahead of Adidas at **$2,902,704.46** (15.32%). LG and Samsung sit close together in the mid-pack (14.58% and 14.39%), while Sony, Nike, and Nestle round out the list, each contributing between 12–14% of total revenue.

## 4. Share of Total Revenue

![Revenue Share Donut](revenue_share_donut.png)

No single brand dominates the portfolio. All seven brands fall within a tight **12.56%–15.75%** band, meaning revenue is fairly evenly distributed rather than concentrated in one or two names.

## 5. Revenue Concentration (Pareto View)

<img width="1400" height="1400" alt="image" src="https://github.com/user-attachments/assets/975d9962-fda1-4507-b63a-3384c47525c3" />


The cumulative curve confirms this balance: the **top 3 brands** (Apple, Adidas, LG) account for only **45.65%** of revenue — far short of an 80/20-style concentration pattern. Reaching 100% requires all seven brands, reinforcing that no brand carries outsized risk or reliance for the business.

## 6. Key Takeaways

- **Balanced portfolio:** With only a 3.19-point spread between the highest and lowest performing brand, revenue risk is well diversified — losing any single brand would not disproportionately impact total revenue.
- **Apple & Adidas lead, but narrowly:** Their combined share (31.07%) is meaningful but not dominant.
- **Nestle is the smallest contributor** at 12.56%, though still within ~2 points of the average (14.29%), so it isn't an outlier — just the tail end of a tightly-clustered group.
- **No long-tail risk:** Because all brands sit close to the mean, this suggests either a curated brand catalog or a mature/stable market where multiple established brands compete evenly.

## 7. Methodology Notes

- `total_amount` is computed via `LEFT JOIN`s from `dim_brands` → `dim_products` → `fact_order_items`, so brands with no products or no orders would still appear with `NULL`/zero revenue (none present in this result set).
- `pct_of_total` is rounded to 2 decimal places using `ROUND(total_amount / grand_revenue * 100, 2)`.
- Charts were generated with **pandas**, **matplotlib**, and **seaborn** from the query's JSON output.

---
*Generated from `brands.sql` output — Gold layer, Brand Revenue Analysis.*
