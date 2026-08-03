-- ============================================================================
-- Objects:      fn_set_bronze_loaded_at, fn_set_silver_loaded_at,
--               fn_set_gold_loaded_at, sp_attach_loaded_at_triggers
-- Purpose:      Auto-stamp each medallion layer's *_loaded_at column with
--               the actual wall-clock write time, instead of relying on the
--               ETL process (PySpark, dbt, PowerShell, etc.) to set it
--               correctly and consistently on every write path. One trigger
--               function per layer, plus a procedure that attaches the
--               right trigger to every table in a schema that has the
--               matching column - so you can deploy this across bronze and
--               gold (and silver, included for completeness) without
--               hand-writing CREATE TRIGGER once per table.
--
-- Why per-layer functions instead of one generic function:
--   The column name differs per layer (bronze_loaded_at vs
--   silver_loaded_at vs gold_loaded_at). A trigger function can only
--   assign to a field on NEW using a name known at parse time - reaching
--   that name dynamically would require the hstore extension or
--   jsonb round-tripping of the whole row, which adds a dependency and a
--   performance cost for no real benefit when there are only three
--   possible column names. Three small, explicit functions are simpler to
--   read, simpler to debug, and cheaper per-row than a dynamic version.
--
-- clock_timestamp() vs now():
--   now() (and CURRENT_TIMESTAMP) is fixed at transaction start, so a
--   multi-row batch insert or a long-running transaction would stamp every
--   row with the same value. clock_timestamp() reflects the actual moment
--   each row is written, which is what "loaded_at" should mean.
--
-- Fires on INSERT and UPDATE:
--   Default here is BEFORE INSERT OR UPDATE, so gold_loaded_at reflects
--   the last time a row was (re)loaded - appropriate if gold is built via
--   incremental MERGE/upsert and a row can be reprocessed. If your
--   pipeline instead treats *_loaded_at as "first load only" and never
--   wants it touched again on update, drop OR UPDATE from the CREATE
--   TRIGGER statements below.
--
-- FLAG - read before deploying:
--   This trigger unconditionally overrides whatever value the INSERT/
--   UPDATE statement provided for the *_loaded_at column, including a
--   value your ETL job explicitly set. That's the point (single
--   DB-side source of truth, no clock skew between the ETL host and
--   Postgres) - but if any incremental/watermark logic downstream reads
--   that column back to decide what's "new" (the way the Museum ETL
--   project's watermark-based extraction does), forcing it to
--   clock_timestamp() at write time changes what that watermark means.
--   Confirm nothing depends on *_loaded_at carrying an ETL-supplied value
--   before attaching this broadly.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_set_bronze_loaded_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.bronze_loaded_at := clock_timestamp();
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION fn_set_silver_loaded_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.silver_loaded_at := clock_timestamp();
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION fn_set_gold_loaded_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.gold_loaded_at := clock_timestamp();
    RETURN NEW;
END;
$function$;

-- ============================================================================
-- Procedure:    sp_attach_loaded_at_triggers
-- Purpose:      Attaches the appropriate *_loaded_at trigger function to
--               every base table in a given schema that has the matching
--               column, replacing any existing trigger of the same name so
--               this is safe to re-run after adding new tables.
--
-- Parameters:
--   p_schema            TEXT - target schema, e.g. 'bronze', 'gold'
--   p_loaded_at_column  TEXT - column to key off, e.g. 'gold_loaded_at'
--   p_trigger_function   TEXT - trigger function to attach, e.g.
--                                'fn_set_gold_loaded_at'
--
-- Security:
--   All identifiers (schema, table, column, function, trigger name) are
--   sourced from the information_schema catalog or from parameters typed
--   as TEXT and interpolated exclusively through %I (quote_ident), never
--   %s or raw concatenation, so this cannot be used for SQL injection.
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_attach_loaded_at_triggers(
    p_schema            TEXT,
    p_loaded_at_column  TEXT,
    p_trigger_function  TEXT
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_tbl           RECORD;
    v_trigger_name  TEXT;
    v_count         INTEGER := 0;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = p_schema) THEN
        RAISE EXCEPTION 'Schema % does not exist', p_schema;
    END IF;

    FOR v_tbl IN
        SELECT t.table_name
        FROM information_schema.tables t
        JOIN information_schema.columns c
            ON c.table_schema = t.table_schema
           AND c.table_name = t.table_name
           AND c.column_name = p_loaded_at_column
        WHERE t.table_schema = p_schema
          AND t.table_type = 'BASE TABLE'
    LOOP
        v_trigger_name := format('trg_%s', p_loaded_at_column);

        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', v_trigger_name, p_schema, v_tbl.table_name);

        EXECUTE format(
            'CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I()',
            v_trigger_name, p_schema, v_tbl.table_name, p_trigger_function
        );

        v_count := v_count + 1;
        RAISE NOTICE 'Attached % to %.%', v_trigger_name, p_schema, v_tbl.table_name;
    END LOOP;

    RAISE NOTICE '========================================';
    RAISE NOTICE 'sp_attach_loaded_at_triggers: attached % trigger(s) to schema %.% tables (column: %)', v_count, p_schema, p_loaded_at_column;
END;
$procedure$;

-- ============================================================================
-- Deployment
-- ============================================================================
-- Attach to every bronze table that has bronze_loaded_at:
--   CALL sp_attach_loaded_at_triggers('bronze', 'bronze_loaded_at', 'fn_set_bronze_loaded_at');
--
-- Attach to every gold table that has gold_loaded_at (dim_customers,
-- dim_orders, fact_order_items, dim_products, dim_categories, dim_brands
-- all qualify based on the columns you've shared):
--   CALL sp_attach_loaded_at_triggers('gold', 'gold_loaded_at', 'fn_set_gold_loaded_at');
--
-- Optional, if silver also carries a silver_loaded_at column:
--   CALL sp_attach_loaded_at_triggers('silver', 'silver_loaded_at', 'fn_set_silver_loaded_at');
--
-- Re-run any of the above any time after adding new tables to a schema -
-- it will only add triggers where the column exists, and replaces any
-- previous trigger of the same name so it's idempotent.
--
-- Verify what's attached:
--   SELECT event_object_schema, event_object_table, trigger_name
--   FROM information_schema.triggers
--   WHERE trigger_name LIKE 'trg_%_loaded_at'
--   ORDER BY event_object_schema, event_object_table;
-- ============================================================================