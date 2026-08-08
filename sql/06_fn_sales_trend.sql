-- ============================================================================
-- Function:     fn_sales_trend_analysis
-- Purpose:      Generates a period-over-period sales trend report. Buckets
--               fact_order_items sales into a dynamic time grain (day, week,
--               month, quarter, year), then uses LAG() and a moving average
--               window function to compute period-over-period revenue and
--               volume growth. Optional filters slice the trend down to a
--               single product, category, brand, or customer.
--
-- Source tables:
--   fact_order_items  - order line items (grain: 1 row per order_item_id)
--   dim_orders        - order header, joined for order_timestamp (the sale
--                        date) and customer_id
--   dim_products      - joined only when p_category_id / p_brand_id filters
--                        are supplied
--
-- Parameters:
--   p_schema                    TEXT     - schema containing the tables
--                                          above (default: 'public').
--                                          Resolved with %I, so it cannot
--                                          be used for SQL injection.
--   p_granularity               TEXT     - day | week | month | quarter |
--                                          year (default: 'month')
--   p_start_date                DATE     - trend window start (default:
--                                          the earliest order_timestamp
--                                          on file)
--   p_end_date                  DATE     - trend window end
--                                          (default: today)
--   p_product_id                INTEGER  - filter fact_order_items.product_id
--   p_category_id               BIGINT   - filter dim_products.category_id
--   p_brand_id                  BIGINT   - filter dim_products.brand_id
--   p_customer_id               INTEGER  - filter dim_orders.customer_id
--   p_include_inactive_items    BOOLEAN  - if FALSE (default), excludes
--                                          fact_order_items and dim_orders
--                                          rows where is_active = FALSE
--   p_moving_avg_periods        INTEGER  - window size for the trailing
--                                          moving average of revenue
--                                          (default: 3, clamped to a
--                                          minimum of 1)
--   p_sort_direction            TEXT     - ASC | DESC on period_start
--                                          (default: ASC, i.e. oldest
--                                          period first, since this is
--                                          a trend)
--
-- Returns:
--   One row per period in [p_start_date, p_end_date] at the requested grain.
--   See column list in RETURNS TABLE below.
--
-- Known issues / flags:
--   1. Gap filling: periods are generated with generate_series() rather than
--      derived only from periods that had sales. A period with zero matching
--      orders still appears with total_revenue = 0. This matters because
--      LAG() is only meaningful if periods are contiguous - without gap
--      filling, a month with zero sales would silently vanish from the
--      series and the next real month's "previous period" would actually be
--      two months prior, understating or fabricating growth.
--   2. Revenue basis: total_revenue is SUM(fact_order_items.line_amount),
--      not dim_orders.total_amount. This is a deliberate choice, not an
--      oversight - filtering by product/category/brand only makes sense at
--      the line-item grain, and mixing order-level totals with item-level
--      filters would misattribute revenue from products not being filtered
--      on. The tradeoff is that this trend excludes any amount on an order
--      that lives outside line items (e.g. shipping or order-level
--      discounts not represented in fact_order_items). For a whole-order
--      revenue trend, aggregate dim_orders.total_amount directly without
--      product/category/brand filters instead.
--   3. Growth percentages return NULL (not 0 or an error) when the prior
--      period's value is zero, since percentage growth off a zero base is
--      undefined. Treat NULL in *_growth_pct as "no comparable prior period"
--      rather than "no growth."
--
-- Security:
--   p_granularity and p_sort_direction are resolved against hard-coded
--   whitelists (CASE expressions) before being concatenated into the
--   dynamic SQL, so they cannot be used for SQL injection despite being
--   interpolated directly. p_schema is resolved with %I. All other filter
--   values pass through format(..., %L). p_moving_avg_periods is typed
--   INTEGER by Postgres before the function body runs, so it is safe to
--   interpolate with %s.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_sales_trend_analysis(
    p_schema TEXT DEFAULT 'public',
    p_granularity TEXT DEFAULT 'month',
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL,
    p_product_id INTEGER DEFAULT NULL,
    p_category_id BIGINT DEFAULT NULL,
    p_brand_id BIGINT DEFAULT NULL,
    p_customer_id INTEGER DEFAULT NULL,
    p_include_inactive_items BOOLEAN DEFAULT FALSE,
    p_moving_avg_periods INTEGER DEFAULT 3,
    p_sort_direction TEXT DEFAULT 'ASC'
)
RETURNS TABLE (
    period_start TIMESTAMP,
    period_label TEXT,
    total_orders INTEGER,
    total_quantity_sold BIGINT,
    total_revenue NUMERIC(14, 2),
    avg_order_value NUMERIC(14, 2),
    prev_period_revenue NUMERIC(14, 2),
    revenue_change NUMERIC(14, 2),
    revenue_growth_pct NUMERIC(10, 2),
    prev_period_quantity BIGINT,
    quantity_change BIGINT,
    quantity_growth_pct NUMERIC(10, 2),
    moving_avg_revenue NUMERIC(14, 2)
)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_item_where       TEXT := 'TRUE';
    v_grain            TEXT;
    v_series_interval  TEXT;
    v_period_format    TEXT;
    v_sort_direction   TEXT;
    v_moving_avg_frame INTEGER;
    v_sql              TEXT;
    v_row_count        INTEGER;
    v_tbl_products     TEXT;
    v_tbl_items        TEXT;
    v_tbl_orders       TEXT;
BEGIN
    v_tbl_products := format('%I.dim_products', p_schema);
    v_tbl_items    := format('%I.fact_order_items', p_schema);
    v_tbl_orders   := format('%I.dim_orders', p_schema);

    IF to_regclass(v_tbl_orders) IS NULL THEN
        RAISE EXCEPTION 'Table % not found. Pass the correct schema via p_schema (e.g. fn_sales_trend_analysis(p_schema := ''gold'')).', v_tbl_orders;
    END IF;

    IF to_regclass(v_tbl_items) IS NULL THEN
        RAISE EXCEPTION 'Table % not found. Pass the correct schema via p_schema.', v_tbl_items;
    END IF;

    -- ------------------------------------------------------------------
    -- Whitelist granularity (drives date_trunc, generate_series step, and
    -- the to_char() display format)
    -- ------------------------------------------------------------------
    v_grain := CASE lower(p_granularity)
        WHEN 'day'     THEN 'day'
        WHEN 'week'    THEN 'week'
        WHEN 'month'   THEN 'month'
        WHEN 'quarter' THEN 'quarter'
        WHEN 'year'    THEN 'year'
        ELSE NULL
    END;

    IF v_grain IS NULL THEN
        RAISE EXCEPTION 'Invalid p_granularity value: %. Allowed: day, week, month, quarter, year', p_granularity;
    END IF;

    v_series_interval := CASE v_grain
        WHEN 'day'     THEN '1 day'
        WHEN 'week'    THEN '1 week'
        WHEN 'month'   THEN '1 month'
        WHEN 'quarter' THEN '3 months'
        WHEN 'year'    THEN '1 year'
    END;

    v_period_format := CASE v_grain
        WHEN 'day'     THEN 'YYYY-MM-DD'
        WHEN 'week'    THEN 'IYYY-"W"IW'
        WHEN 'month'   THEN 'YYYY-MM'
        WHEN 'quarter' THEN 'YYYY-"Q"Q'
        WHEN 'year'    THEN 'YYYY'
    END;

    -- ------------------------------------------------------------------
    -- Whitelist sort direction
    -- ------------------------------------------------------------------
    v_sort_direction := CASE upper(p_sort_direction)
        WHEN 'ASC'  THEN 'ASC'
        WHEN 'DESC' THEN 'DESC'
        ELSE NULL
    END;

    IF v_sort_direction IS NULL THEN
        RAISE EXCEPTION 'Invalid p_sort_direction value: %. Allowed: ASC, DESC', p_sort_direction;
    END IF;

    -- moving average window = N-1 preceding rows + current row
    v_moving_avg_frame := GREATEST(COALESCE(p_moving_avg_periods, 3), 1) - 1;

    -- ------------------------------------------------------------------
    -- Build fact_order_items / dim_orders / dim_products filter fragment
    -- ------------------------------------------------------------------
    IF NOT p_include_inactive_items THEN
        v_item_where := v_item_where || ' AND foi.is_active = TRUE AND o.is_active = TRUE';
    END IF;

    IF p_product_id IS NOT NULL THEN
        v_item_where := v_item_where || format(' AND foi.product_id = %L', p_product_id);
    END IF;

    IF p_category_id IS NOT NULL THEN
        v_item_where := v_item_where || format(' AND p.category_id = %L', p_category_id);
    END IF;

    IF p_brand_id IS NOT NULL THEN
        v_item_where := v_item_where || format(' AND p.brand_id = %L', p_brand_id);
    END IF;

    IF p_customer_id IS NOT NULL THEN
        v_item_where := v_item_where || format(' AND o.customer_id = %L', p_customer_id);
    END IF;

    RAISE NOTICE '========================================';
    RAISE NOTICE 'fn_sales_trend_analysis | filters applied';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'schema: % | granularity: % | date range: % to %', p_schema, v_grain, p_start_date, p_end_date;
    RAISE NOTICE 'product_id: % | category_id: % | brand_id: % | customer_id: %', p_product_id, p_category_id, p_brand_id, p_customer_id;
    RAISE NOTICE 'include_inactive_items: % | moving_avg_periods: % | sort: %', p_include_inactive_items, v_moving_avg_frame + 1, v_sort_direction;

    -- ------------------------------------------------------------------
    -- Build and execute the trend query
    --
    -- bounds     : resolves the trend window, defaulting to the full
    --              order history when p_start_date/p_end_date are NULL
    -- periods    : gap-filled calendar buckets at the requested grain
    -- sales_agg  : fact_order_items grain aggregates rolled up to period
    -- final SELECT: LEFT JOIN periods -> sales_agg (zero-fills gaps),
    --              then LAG()/AVG() OVER() for trend metrics
    -- ------------------------------------------------------------------
    v_sql := format($sql$
        WITH bounds AS (
            SELECT
                COALESCE(%L::date, (SELECT MIN(order_timestamp)::date FROM %s)) AS start_date,
                COALESCE(%L::date, CURRENT_DATE) AS end_date
        ),
        periods AS (
            SELECT generate_series(
                date_trunc(%L, (SELECT start_date FROM bounds)::timestamp),
                date_trunc(%L, (SELECT end_date FROM bounds)::timestamp),
                %L::interval
            ) AS period_start
        ),
        sales_agg AS (
            SELECT
                date_trunc(%L, o.order_timestamp) AS period_start,
                COUNT(DISTINCT foi.order_id)       AS total_orders,
                SUM(foi.quantity)                  AS total_quantity_sold,
                SUM(foi.line_amount)                AS total_revenue
            FROM %s foi
            JOIN %s o ON o.order_id = foi.order_id
            LEFT JOIN %s p ON p.product_id = foi.product_id
            WHERE %s
              AND o.order_timestamp >= (SELECT start_date FROM bounds)
              AND o.order_timestamp <  (SELECT end_date FROM bounds) + 1
            GROUP BY date_trunc(%L, o.order_timestamp)
        )
        SELECT
            per.period_start,
            to_char(per.period_start, %L) AS period_label,
            COALESCE(sa.total_orders, 0)::INTEGER          AS total_orders,
            COALESCE(sa.total_quantity_sold, 0)::BIGINT    AS total_quantity_sold,
            COALESCE(sa.total_revenue, 0)::NUMERIC(14,2)   AS total_revenue,
            CASE WHEN COALESCE(sa.total_orders, 0) > 0
                 THEN ROUND(sa.total_revenue / sa.total_orders, 2)
                 ELSE 0::NUMERIC(14,2)
            END AS avg_order_value,
            LAG(COALESCE(sa.total_revenue, 0)) OVER (ORDER BY per.period_start)::NUMERIC(14,2) AS prev_period_revenue,
            (COALESCE(sa.total_revenue, 0) - LAG(COALESCE(sa.total_revenue, 0)) OVER (ORDER BY per.period_start))::NUMERIC(14,2) AS revenue_change,
            CASE WHEN LAG(COALESCE(sa.total_revenue, 0)) OVER (ORDER BY per.period_start) > 0
                 THEN ROUND(
                          (COALESCE(sa.total_revenue, 0) - LAG(COALESCE(sa.total_revenue, 0)) OVER (ORDER BY per.period_start))
                          / LAG(COALESCE(sa.total_revenue, 0)) OVER (ORDER BY per.period_start) * 100, 2)
                 ELSE NULL
            END AS revenue_growth_pct,
            LAG(COALESCE(sa.total_quantity_sold, 0)) OVER (ORDER BY per.period_start)::BIGINT AS prev_period_quantity,
            (COALESCE(sa.total_quantity_sold, 0) - LAG(COALESCE(sa.total_quantity_sold, 0)) OVER (ORDER BY per.period_start))::BIGINT AS quantity_change,
            CASE WHEN LAG(COALESCE(sa.total_quantity_sold, 0)) OVER (ORDER BY per.period_start) > 0
                 THEN ROUND(
                          (COALESCE(sa.total_quantity_sold, 0) - LAG(COALESCE(sa.total_quantity_sold, 0)) OVER (ORDER BY per.period_start))::numeric
                          / LAG(COALESCE(sa.total_quantity_sold, 0)) OVER (ORDER BY per.period_start) * 100, 2)
                 ELSE NULL
            END AS quantity_growth_pct,
            ROUND(AVG(COALESCE(sa.total_revenue, 0)) OVER (
                ORDER BY per.period_start ROWS BETWEEN %s PRECEDING AND CURRENT ROW
            ), 2) AS moving_avg_revenue
        FROM periods per
        LEFT JOIN sales_agg sa ON sa.period_start = per.period_start
        ORDER BY per.period_start %s
    $sql$,
        p_start_date, v_tbl_orders, p_end_date,
        v_grain, v_grain, v_series_interval,
        v_grain, v_tbl_items, v_tbl_orders, v_tbl_products, v_item_where, v_grain,
        v_period_format, v_moving_avg_frame, v_sort_direction
    );

    RETURN QUERY EXECUTE v_sql;

    GET DIAGNOSTICS v_row_count = ROW_COUNT;
    RAISE NOTICE 'fn_sales_trend_analysis returned % period(s)', v_row_count;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'fn_sales_trend_analysis failed: % | SQLSTATE: % | Generated SQL: %', SQLERRM, SQLSTATE, v_sql;
END;
$function$;

-- ============================================================================
-- Example usage
-- ============================================================================
-- Monthly revenue trend, full order history (tables in 'gold' schema):
--   SELECT * FROM fn_sales_trend_analysis(p_schema := 'gold');
--
-- Weekly trend for one product, last 90 days:
--   SELECT * FROM fn_sales_trend_analysis(
--       p_schema      := 'gold',
--       p_granularity := 'week',
--       p_product_id  := 218,
--       p_start_date  := CURRENT_DATE - INTERVAL '90 days',
--       p_end_date    := CURRENT_DATE
--   );
--
-- Quarterly trend for a category, most recent quarter first:
--   SELECT * FROM fn_sales_trend_analysis(
--       p_schema      := 'gold',
--       p_granularity := 'quarter',
--       p_category_id := 4,
--       p_sort_direction := 'DESC'
--   );
--
-- Find the periods with the sharpest revenue decline:
--   SELECT period_label, total_revenue, revenue_change, revenue_growth_pct
--   FROM fn_sales_trend_analysis(p_schema := 'gold', p_granularity := 'month')
--   WHERE revenue_growth_pct IS NOT NULL
--   ORDER BY revenue_growth_pct ASC
--   LIMIT 5;
-- ============================================================================
