-- ============================================================================
-- Function:     fn_customer_report
-- Purpose:      Generates a dynamic, filterable customer activity report by
--               aggregating order and order-item facts against dim_customers.
--               Filter conditions, sort column, sort direction, and row limit
--               are all resolved at runtime via dynamic SQL (EXECUTE), so the
--               function serves ad-hoc reporting needs without needing a
--               separate query per use case.
--
-- Source tables:
--   dim_customers     - customer master (grain: 1 row per customer_id)
--   dim_orders        - order header (grain: 1 row per order_id)
--   fact_order_items  - order line items (grain: 1 row per order_item_id)
--
-- Parameters:
--   p_schema                     TEXT      - schema containing dim_customers,
--                                          dim_orders, fact_order_items
--                                          (default: 'public'). Tables are
--                                          resolved with %I so this cannot
--                                          be used for SQL injection.
--   p_customer_id               INTEGER   - filter to a single customer_id
--   p_start_date                DATE      - order_timestamp lower bound
--                                          (inclusive)
--   p_end_date                  DATE      - order_timestamp upper bound
--                                          (inclusive)
--   p_order_status              VARCHAR  - filter dim_orders.order_status
--   p_is_active                 BOOLEAN - filter dim_customers.is_active
--   p_include_inactive_orders   BOOLEAN - if FALSE (default), excludes orders
--                                          and order items where
--                                          is_active = FALSE
--   p_country                   VARCHAR - filter dim_customers.country
--   p_province                  VARCHAR - filter dim_customers.province
--   p_city                      VARCHAR - filter dim_customers.city
--   p_sort_by                   TEXT    - one of: total_orders, total_items,
--                                          total_spent, avg_order_value,
--                                          first_order_date, last_order_date,
--                                          customer_name, days_since_last_order
--                                          (default: total_spent)
--   p_sort_direction            TEXT   - ASC | DESC (default: DESC)
--   p_limit                     INTEGER - cap on returned rows
--                                          (default: no cap)
--
-- Returns:
--   TABLE of one row per customer matching the filters, with order/item
--   aggregates. See column list in RETURNS TABLE below.
--
-- Known issue / flag:
--   total_spent is derived from dim_orders.total_amount (order-header grain,
--   no fan-out risk). total_line_item_amount is derived independently from
--   fact_order_items.line_amount. These two are NOT guaranteed to match if
--   total_amount includes tax, shipping, or discounts that aren't captured
--   at the line-item level. amount_variance surfaces that gap so it can be
--   reconciled rather than silently trusting one number. If this project's
--   business rule is "total_amount == SUM(line_amount)", a non-zero variance
--   indicates a data quality issue upstream, not a bug in this function.
--
-- Security:
--   p_sort_by and p_sort_direction are resolved against a hard-coded
--   whitelist (CASE expression) before being concatenated into the dynamic
--   SQL string, so they cannot be used for SQL injection despite being
--   interpolated directly. All other filter values are passed through
--   format(..., %L) which quotes/escapes literals safely. p_limit is typed
--   INTEGER by Postgres before the function body ever runs, so it is safe
--   to interpolate with %s.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_customer_report(
    p_schema TEXT DEFAULT 'public',
    p_customer_id INTEGER DEFAULT NULL,
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL,
    p_order_status VARCHAR DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL,
    p_include_inactive_orders BOOLEAN DEFAULT FALSE,
    p_country VARCHAR DEFAULT NULL,
    p_province VARCHAR DEFAULT NULL,
    p_city VARCHAR DEFAULT NULL,
    p_sort_by TEXT DEFAULT 'total_spent',
    p_sort_direction TEXT DEFAULT 'DESC',
    p_limit INTEGER DEFAULT NULL
)
RETURNS TABLE (
    customer_id INTEGER,
    customer_name VARCHAR,
    phone TEXT,
    email VARCHAR,
    city VARCHAR,
    province VARCHAR,
    country VARCHAR,
    is_active BOOLEAN,
    total_orders INTEGER,
    total_items BIGINT,
    total_spent NUMERIC(14, 2),
    total_line_item_amount NUMERIC(14, 2),
    amount_variance NUMERIC(14, 2),
    avg_order_value NUMERIC(14, 2),
    first_order_date TIMESTAMP,
    last_order_date TIMESTAMP,
    days_since_last_order INTEGER
)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_order_where     TEXT := 'TRUE';
    v_customer_where  TEXT := 'TRUE';
    v_sort_column     TEXT;
    v_sort_direction  TEXT;
    v_limit_clause    TEXT := '';
    v_sql             TEXT;
    v_row_count       INTEGER;
    v_tbl_customers   TEXT;
    v_tbl_orders      TEXT;
    v_tbl_items       TEXT;
BEGIN
    -- Schema-qualify every table reference so this works regardless of the
    -- calling role's search_path (e.g. medallion setups with separate
    -- bronze/silver/gold schemas). quote_ident via %I prevents injection
    -- through p_schema.
    v_tbl_customers := format('%I.dim_customers', p_schema);
    v_tbl_orders     := format('%I.dim_orders', p_schema);
    v_tbl_items      := format('%I.fact_order_items', p_schema);

    IF to_regclass(v_tbl_orders) IS NULL THEN
        RAISE EXCEPTION 'Table % not found. Pass the correct schema via p_schema (e.g. fn_customer_report(p_schema := ''gold'')). Run \dt *.dim_orders in psql to locate it.', v_tbl_orders;
    END IF;
    -- ------------------------------------------------------------------
    -- Build order/order-item level filter fragment
    -- (shared by both the order_agg and item_agg CTEs below, since both
    --  are grouped from dim_orders and need identical scoping)
    -- ------------------------------------------------------------------
    IF NOT p_include_inactive_orders THEN
        v_order_where := v_order_where || ' AND o.is_active = TRUE';
    END IF;

    IF p_customer_id IS NOT NULL THEN
        v_order_where := v_order_where || format(' AND o.customer_id = %L', p_customer_id);
    END IF;

    IF p_start_date IS NOT NULL THEN
        v_order_where := v_order_where || format(' AND o.order_timestamp >= %L', p_start_date);
    END IF;

    IF p_end_date IS NOT NULL THEN
        v_order_where := v_order_where || format(' AND o.order_timestamp < %L', p_end_date + 1);
    END IF;

    IF p_order_status IS NOT NULL THEN
        v_order_where := v_order_where || format(' AND o.order_status = %L', p_order_status);
    END IF;

    -- ------------------------------------------------------------------
    -- Build customer-level filter fragment
    -- ------------------------------------------------------------------
    IF p_customer_id IS NOT NULL THEN
        v_customer_where := v_customer_where || format(' AND c.customer_id = %L', p_customer_id);
    END IF;

    IF p_is_active IS NOT NULL THEN
        v_customer_where := v_customer_where || format(' AND c.is_active = %L', p_is_active);
    END IF;

    IF p_country IS NOT NULL THEN
        v_customer_where := v_customer_where || format(' AND c.country ILIKE %L', p_country);
    END IF;

    IF p_province IS NOT NULL THEN
        v_customer_where := v_customer_where || format(' AND c.province ILIKE %L', p_province);
    END IF;

    IF p_city IS NOT NULL THEN
        v_customer_where := v_customer_where || format(' AND c.city ILIKE %L', p_city);
    END IF;

    -- ------------------------------------------------------------------
    -- Whitelist sort column / direction (prevents SQL injection via
    -- p_sort_by / p_sort_direction, since these get concatenated raw)
    -- ------------------------------------------------------------------
    v_sort_column := CASE lower(p_sort_by)
        WHEN 'total_orders'          THEN 'total_orders'
        WHEN 'total_items'           THEN 'total_items'
        WHEN 'total_spent'           THEN 'total_spent'
        WHEN 'avg_order_value'       THEN 'avg_order_value'
        WHEN 'first_order_date'      THEN 'first_order_date'
        WHEN 'last_order_date'       THEN 'last_order_date'
        WHEN 'customer_name'         THEN 'customer_name'
        WHEN 'days_since_last_order' THEN 'days_since_last_order'
        ELSE NULL
    END;

    IF v_sort_column IS NULL THEN
        RAISE EXCEPTION 'Invalid p_sort_by value: %. Allowed: total_orders, total_items, total_spent, avg_order_value, first_order_date, last_order_date, customer_name, days_since_last_order', p_sort_by;
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
    RAISE NOTICE 'fn_customer_report | filters applied';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'schema: % | customer_id: % | date range: % to % | status: %', p_schema, p_customer_id, p_start_date, p_end_date, p_order_status;
    RAISE NOTICE 'is_active: % | include_inactive_orders: % | geo: %/%/%', p_is_active, p_include_inactive_orders, p_city, p_province, p_country;
    RAISE NOTICE 'sort: % % | limit: %', v_sort_column, v_sort_direction, p_limit;

    -- ------------------------------------------------------------------
    -- Build and execute the report query
    --
    -- order_agg  : order-header grain aggregates (no fan-out risk)
    -- item_agg   : order-item grain aggregates, rolled up to customer via
    --              dim_orders so item filters and order filters stay in sync
    -- ------------------------------------------------------------------
    v_sql := format($sql$
        WITH order_agg AS (
            SELECT
                o.customer_id,
                COUNT(*)                AS total_orders,
                SUM(o.total_amount)     AS total_order_amount,
                MIN(o.order_timestamp)  AS first_order_date,
                MAX(o.order_timestamp)  AS last_order_date
            FROM %s o
            WHERE %s
            GROUP BY o.customer_id
        ),
        item_agg AS (
            SELECT
                o.customer_id,
                SUM(foi.quantity)      AS total_items,
                SUM(foi.line_amount)   AS total_line_item_amount
            FROM %s o
            JOIN %s foi
                ON foi.order_id = o.order_id
               AND foi.is_active = TRUE
            WHERE %s
            GROUP BY o.customer_id
        )
        SELECT
            c.customer_id,
            c.customer_name,
            c.phone,
            c.email,
            c.city,
            c.province,
            c.country,
            c.is_active,
            COALESCE(oa.total_orders, 0)::INTEGER                          AS total_orders,
            COALESCE(ia.total_items, 0)::BIGINT                            AS total_items,
            COALESCE(oa.total_order_amount, 0)::NUMERIC(14,2)              AS total_spent,
            COALESCE(ia.total_line_item_amount, 0)::NUMERIC(14,2)          AS total_line_item_amount,
            (COALESCE(oa.total_order_amount, 0) - COALESCE(ia.total_line_item_amount, 0))::NUMERIC(14,2) AS amount_variance,
            CASE WHEN COALESCE(oa.total_orders, 0) > 0
                 THEN ROUND(oa.total_order_amount / oa.total_orders, 2)
                 ELSE 0::NUMERIC(14,2)
            END                                                            AS avg_order_value,
            oa.first_order_date,
            oa.last_order_date,
            CASE WHEN oa.last_order_date IS NOT NULL
                 THEN (CURRENT_DATE - oa.last_order_date::date)::INTEGER
                 ELSE NULL
            END                                                            AS days_since_last_order
        FROM %s c
        LEFT JOIN order_agg oa ON oa.customer_id = c.customer_id
        LEFT JOIN item_agg  ia ON ia.customer_id = c.customer_id
        WHERE %s
        ORDER BY %s %s NULLS LAST
        %s
    $sql$, v_tbl_orders, v_order_where, v_tbl_orders, v_tbl_items, v_order_where,
           v_tbl_customers, v_customer_where, v_sort_column, v_sort_direction, v_limit_clause);

    RETURN QUERY EXECUTE v_sql;

    GET DIAGNOSTICS v_row_count = ROW_COUNT;
    RAISE NOTICE 'fn_customer_report returned % row(s)', v_row_count;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'fn_customer_report failed: % | SQLSTATE: % | Generated SQL: %', SQLERRM, SQLSTATE, v_sql;
END;
$function$;

-- ============================================================================
-- Example usage
-- ============================================================================
-- Top 10 customers by spend, active customers only (tables in 'gold' schema):
--   SELECT * FROM fn_customer_report(
--       p_schema := 'gold', p_is_active := TRUE, p_limit := 10
--   );
--
-- Single customer, full history:
--   SELECT * FROM fn_customer_report(
--       p_schema := 'gold', p_customer_id := 4521
--   );
--
-- Delhi customers, orders in Q1 2026, sorted by most recent order:
--   SELECT * FROM fn_customer_report(
--       p_schema := 'gold',
--       p_city := 'Delhi',
--       p_start_date := '2026-01-01',
--       p_end_date   := '2026-03-31',
--       p_sort_by    := 'last_order_date',
--       p_sort_direction := 'DESC'
--   );
--
-- Reconciliation check - customers where order total and line-item total
-- disagree by more than a rounding tolerance:
--   SELECT customer_id, customer_name, total_spent,
--          total_line_item_amount, amount_variance
--   FROM fn_customer_report(p_schema := 'gold')
--   WHERE ABS(amount_variance) > 0.01
--   ORDER BY ABS(amount_variance) DESC;
-- ============================================================================
