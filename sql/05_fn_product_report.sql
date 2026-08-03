-- ============================================================================
-- Function:     fn_product_report
-- Purpose:      Generates a dynamic, filterable product performance report by
--               aggregating fact_order_items sales activity (joined through
--               dim_orders for sale dates) against dim_products, dim_brands,
--               and dim_categories. Filters, sort column, sort direction, and
--               row limit are all resolved at runtime via dynamic SQL.
--
-- Source tables:
--   dim_products           - product master (grain: 1 row per product_id)
--   dim_categories         - category lookup (grain: 1 row per category_id)
--   dim_brands             - brand lookup (grain: 1 row per brand_id)
--   fact_order_items       - order line items (grain: 1 row per order_item_id)
--   dim_orders             - order header, joined in only to recover the
--                            order_timestamp for sale-date filtering, since
--                            fact_order_items only carries created_timestamp
--                            (ETL load time, not sale date)
--
-- Parameters:
--   p_schema                       TEXT       - schema containing all five tables
--                                               above (default: 'public').
--                                               Resolved with %I, so it cannot be
--                                               used for SQL injection.
--   p_product_id                   INTEGER    - filter to a single product_id
--   p_category_id                  BIGINT     - filter dim_products.category_id
--   p_brand_id                     BIGINT     - filter dim_products.brand_id
--   p_category_name                VARCHAR    - ILIKE match on category_name
--   p_brand_name                   VARCHAR    - ILIKE match on brand_name
--   p_is_active                    BOOLEAN    - filter dim_products.is_active
--   p_include_inactive_items       BOOLEAN    - if FALSE (default), excludes
--                                                 fact_order_items and
--                                                 dim_orders rows where
--                                                 is_active = FALSE
--   p_start_date                   DATE        - order_timestamp lower bound
--   p_end_date                     DATE        - order_timestamp upper bound
--   p_min_price                    NUMERIC     - filter dim_products.price >=
--   p_max_price                    NUMERIC     - filter dim_products.price <=
--   p_sort_by                      TEXT        - one of: total_orders,
--                                                    total_quantity_sold,
--                                                    total_revenue,
--                                                    avg_selling_price, price,
--                                                    product_name,
--                                                    first_sold_date,
--                                                    last_sold_date,
--                                                    days_since_last_sale
--                                                    (default: total_revenue)
--   p_sort_direction               TEXT        - ASC | DESC (default: DESC)
--   p_limit                        NTEGER      - cap on returned rows
--
-- Returns:
--   TABLE of one row per product matching the filters, with sales aggregates.
--   See column list in RETURNS TABLE below.
--
-- Known issue / flag:
--   price is dim_products.price - the CURRENT catalog price at query time.
--   avg_selling_price is derived from actual fact_order_items.line_amount /
--   quantity, i.e. what customers were actually charged historically.
--   price_variance = price - avg_selling_price surfaces the gap between the
--   two. A non-zero variance is expected if the catalog price has changed
--   since past sales, or if discounts were applied at the line-item level -
--   it is not automatically a data quality bug, but it is worth reviewing
--   for products with unexpectedly large variance.
--
-- Security:
--   p_sort_by / p_sort_direction are resolved against a hard-coded whitelist
--   (CASE expression) before being concatenated into the dynamic SQL, so
--   they cannot be used for SQL injection despite being interpolated
--   directly. p_schema is resolved with %I (quote_ident). All other filter
--   values pass through format(..., %L). p_limit is typed INTEGER by
--   Postgres before the function body runs, so it is safe to interpolate
--   with %s.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_product_report(
    p_schema                        TEXT        DEFAULT 'public',
    p_product_id                    INTEGER     DEFAULT NULL,
    p_category_id                   BIGINT      DEFAULT NULL,
    p_brand_id                      BIGINT      DEFAULT NULL,
    p_category_name                 VARCHAR     DEFAULT NULL,
    p_brand_name                    VARCHAR     DEFAULT NULL,
    p_is_active                     BOOLEAN     DEFAULT NULL,
    p_include_inactive_items        BOOLEAN     DEFAULT FALSE,
    p_start_date                    DATE        DEFAULT NULL,
    p_end_date                      DATE        DEFAULT NULL,
    p_min_price                     NUMERIC     DEFAULT NULL,
    p_max_price                     NUMERIC     DEFAULT NULL,
    p_sort_by                       TEXT        DEFAULT 'total_revenue',
    p_sort_direction                TEXT        DEFAULT 'DESC',
    p_limit                         INTEGER     DEFAULT NULL
)
RETURNS TABLE (
    product_id                  INTEGER,
    product_name                VARCHAR,
    brand_name                  TEXT,
    category_name               TEXT,
    price                       NUMERIC(14,2),
    is_active                   BOOLEAN,
    total_orders                INTEGER,
    total_quantity_sold         BIGINT,
    total_revenue               NUMERIC(14,2),
    avg_selling_price           NUMERIC(14,2),
    price_variance              NUMERIC(14,2),
    first_sold_date             TIMESTAMP,
    last_sold_date              TIMESTAMP,
    days_since_last_sale        INTEGER
)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_item_where      TEXT := 'TRUE';
    v_product_where   TEXT := 'TRUE';
    v_sort_column     TEXT;
    v_sort_direction  TEXT;
    v_limit_clause    TEXT := '';
    v_sql             TEXT;
    v_row_count       INTEGER;
    v_tbl_products    TEXT;
    v_tbl_categories  TEXT;
    v_tbl_brands      TEXT;
    v_tbl_items       TEXT;
    v_tbl_orders      TEXT;
BEGIN
    -- Schema-qualify every table reference so this works regardless of the
    -- calling role's search_path. quote_ident via %I prevents injection
    -- through p_schema.
    v_tbl_products   := format('%I.dim_products', p_schema);
    v_tbl_categories := format('%I.dim_categories', p_schema);
    v_tbl_brands     := format('%I.dim_brands', p_schema);
    v_tbl_items      := format('%I.fact_order_items', p_schema);
    v_tbl_orders     := format('%I.dim_orders', p_schema);

    IF to_regclass(v_tbl_products) IS NULL THEN
        RAISE EXCEPTION 'Table % not found. Pass the correct schema via p_schema (e.g. fn_product_report(p_schema := ''gold'')).', v_tbl_products;
    END IF;

    -- ------------------------------------------------------------------
    -- Build fact_order_items / dim_orders filter fragment
    -- (shared scoping for the sales_agg CTE below)
    -- ------------------------------------------------------------------
    IF NOT p_include_inactive_items THEN
        v_item_where := v_item_where || ' AND foi.is_active = TRUE AND o.is_active = TRUE';
    END IF;

    IF p_product_id IS NOT NULL THEN
        v_item_where := v_item_where || format(' AND foi.product_id = %L', p_product_id);
    END IF;

    IF p_start_date IS NOT NULL THEN
        v_item_where := v_item_where || format(' AND o.order_timestamp >= %L', p_start_date);
    END IF;

    IF p_end_date IS NOT NULL THEN
        v_item_where := v_item_where || format(' AND o.order_timestamp < %L', p_end_date + 1);
    END IF;

    -- ------------------------------------------------------------------
    -- Build product-level filter fragment
    -- ------------------------------------------------------------------
    IF p_product_id IS NOT NULL THEN
        v_product_where := v_product_where || format(' AND p.product_id = %L', p_product_id);
    END IF;

    IF p_category_id IS NOT NULL THEN
        v_product_where := v_product_where || format(' AND p.category_id = %L', p_category_id);
    END IF;

    IF p_brand_id IS NOT NULL THEN
        v_product_where := v_product_where || format(' AND p.brand_id = %L', p_brand_id);
    END IF;

    IF p_category_name IS NOT NULL THEN
        v_product_where := v_product_where || format(' AND cat.category_name ILIKE %L', p_category_name);
    END IF;

    IF p_brand_name IS NOT NULL THEN
        v_product_where := v_product_where || format(' AND b.brand_name ILIKE %L', p_brand_name);
    END IF;

    IF p_is_active IS NOT NULL THEN
        v_product_where := v_product_where || format(' AND p.is_active = %L', p_is_active);
    END IF;

    IF p_min_price IS NOT NULL THEN
        v_product_where := v_product_where || format(' AND p.price >= %L', p_min_price);
    END IF;

    IF p_max_price IS NOT NULL THEN
        v_product_where := v_product_where || format(' AND p.price <= %L', p_max_price);
    END IF;

    -- ------------------------------------------------------------------
    -- Whitelist sort column / direction (prevents SQL injection via
    -- p_sort_by / p_sort_direction, since these get concatenated raw)
    -- ------------------------------------------------------------------
    v_sort_column := CASE lower(p_sort_by)
        WHEN 'total_orders'          THEN 'total_orders'
        WHEN 'total_quantity_sold'   THEN 'total_quantity_sold'
        WHEN 'total_revenue'         THEN 'total_revenue'
        WHEN 'avg_selling_price'     THEN 'avg_selling_price'
        WHEN 'price'                 THEN 'price'
        WHEN 'product_name'          THEN 'product_name'
        WHEN 'first_sold_date'       THEN 'first_sold_date'
        WHEN 'last_sold_date'        THEN 'last_sold_date'
        WHEN 'days_since_last_sale'  THEN 'days_since_last_sale'
        ELSE NULL
    END;

    IF v_sort_column IS NULL THEN
        RAISE EXCEPTION 'Invalid p_sort_by value: %. Allowed: total_orders, total_quantity_sold, total_revenue, avg_selling_price, price, product_name, first_sold_date, last_sold_date, days_since_last_sale', p_sort_by;
    END IF;

    v_sort_direction := CASE upper(p_sort_direction)
        WHEN 'ASC'  THEN 'ASC'
        WHEN 'DESC' THEN 'DESC'
        ELSE NULL
    END;

    IF v_sort_direction IS NULL THEN
        RAISE EXCEPTION 'Invalid p_sort_direction value: %. Allowed: ASC, DESC', p_sort_direction;
    END IF;

    IF p_limit IS NOT NULL THEN
        v_limit_clause := format('LIMIT %s', p_limit);
    END IF;

    RAISE NOTICE '========================================';
    RAISE NOTICE 'fn_product_report | filters applied';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'schema: % | product_id: % | category_id: % | brand_id: %', p_schema, p_product_id, p_category_id, p_brand_id;
    RAISE NOTICE 'category: % | brand: % | is_active: % | include_inactive_items: %', p_category_name, p_brand_name, p_is_active, p_include_inactive_items;
    RAISE NOTICE 'date range: % to % | price range: % to %', p_start_date, p_end_date, p_min_price, p_max_price;
    RAISE NOTICE 'sort: % % | limit: %', v_sort_column, v_sort_direction, p_limit;

    -- ------------------------------------------------------------------
    -- Build and execute the report query
    --
    -- sales_agg : fact_order_items grain aggregates, rolled up to product,
    --             joined to dim_orders only to recover order_timestamp for
    --             date filtering (no fan-out risk since fact_order_items
    --             is already the finest grain in play)
    -- ------------------------------------------------------------------
    v_sql := format($sql$
        WITH sales_agg AS (
            SELECT
                foi.product_id,
                COUNT(DISTINCT foi.order_id) AS total_orders,
                SUM(foi.quantity)            AS total_quantity_sold,
                SUM(foi.line_amount)         AS total_revenue,
                MIN(o.order_timestamp)       AS first_sold_date,
                MAX(o.order_timestamp)       AS last_sold_date
            FROM %s foi
            JOIN %s o ON o.order_id = foi.order_id
            WHERE %s
            GROUP BY foi.product_id
        )
        SELECT
            p.product_id,
            p.product_name,
            b.brand_name,
            cat.category_name,
            p.price::NUMERIC(14,2)                                          AS price,
            p.is_active,
            COALESCE(sa.total_orders, 0)::INTEGER                           AS total_orders,
            COALESCE(sa.total_quantity_sold, 0)::BIGINT                     AS total_quantity_sold,
            COALESCE(sa.total_revenue, 0)::NUMERIC(14,2)                    AS total_revenue,
            CASE WHEN COALESCE(sa.total_quantity_sold, 0) > 0
                 THEN ROUND(sa.total_revenue / sa.total_quantity_sold, 2)
                 ELSE 0::NUMERIC(14,2)
            END                                                             AS avg_selling_price,
            (p.price - CASE WHEN COALESCE(sa.total_quantity_sold, 0) > 0
                            THEN ROUND(sa.total_revenue / sa.total_quantity_sold, 2)
                            ELSE p.price
                       END)::NUMERIC(14,2)                                  AS price_variance,
            sa.first_sold_date,
            sa.last_sold_date,
            CASE WHEN sa.last_sold_date IS NOT NULL
                 THEN (CURRENT_DATE - sa.last_sold_date::date)::INTEGER
                 ELSE NULL
            END                                                             AS days_since_last_sale
        FROM %s p
        LEFT JOIN %s cat ON cat.category_id = p.category_id
        LEFT JOIN %s b   ON b.brand_id = p.brand_id
        LEFT JOIN sales_agg sa ON sa.product_id = p.product_id
        WHERE %s
        ORDER BY %s %s NULLS LAST
        %s
    $sql$, v_tbl_items, v_tbl_orders, v_item_where,
           v_tbl_products, v_tbl_categories, v_tbl_brands, v_product_where,
           v_sort_column, v_sort_direction, v_limit_clause);

    RETURN QUERY EXECUTE v_sql;

    GET DIAGNOSTICS v_row_count = ROW_COUNT;
    RAISE NOTICE 'fn_product_report returned % row(s)', v_row_count;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'fn_product_report failed: % | SQLSTATE: % | Generated SQL: %', SQLERRM, SQLSTATE, v_sql;
END;
$function$;

-- ============================================================================
-- Example usage
-- ============================================================================
-- Top 10 products by revenue (tables in 'gold' schema):
--   SELECT * FROM fn_product_report(p_schema := 'gold', p_limit := 10);
--
-- Single product, full sales history:
--   SELECT * FROM fn_product_report(p_schema := 'gold', p_product_id := 218);
--
-- Active products in a category, sold in Q1 2026, sorted by units moved:
--   SELECT * FROM fn_product_report(
--       p_schema := 'gold',
--       p_category_name := 'Prints',
--       p_is_active := TRUE,
--       p_start_date := '2026-01-01',
--       p_end_date   := '2026-03-31',
--       p_sort_by    := 'total_quantity_sold',
--       p_sort_direction := 'DESC'
--   );
--
-- Products never sold in the active window (candidates for markdown/EOL):
--   SELECT product_id, product_name, price, total_orders
--   FROM fn_product_report(p_schema := 'gold')
--   WHERE total_orders = 0;
--
-- Reconciliation check - products where realized selling price drifts far
-- from current catalog price (possible stale pricing or heavy discounting):
--   SELECT product_id, product_name, price, avg_selling_price, price_variance
--   FROM fn_product_report(p_schema := 'gold')
--   WHERE ABS(price_variance) > 5
--   ORDER BY ABS(price_variance) DESC;
-- ============================================================================