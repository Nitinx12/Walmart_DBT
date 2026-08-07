/*
===============================================================================
 Script Name : lp_check_nulls.sql
 Description : Check all tables in the silver schema for unexpected NULL values.
===============================================================================
*/

DO $$
DECLARE
    tbl RECORD;
    col RECORD;
    null_count BIGINT;
    has_nulls BOOLEAN;
    any_nulls BOOLEAN := FALSE;
    fail_msg TEXT := '';

    -- Columns where NULLs are allowed
    ignored_columns TEXT[] := ARRAY[
        'customers.phone_extension'
    ];
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Checking NULL values in Silver Schema';
    RAISE NOTICE '========================================';

    FOR tbl IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'silver'
          AND table_type = 'BASE TABLE'
        ORDER BY table_name
    LOOP
        has_nulls := FALSE;

        RAISE NOTICE '';
        RAISE NOTICE 'Table: %', tbl.table_name;

        FOR col IN
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = 'silver'
              AND table_name = tbl.table_name
            ORDER BY ordinal_position
        LOOP
            -- Skip columns where NULLs are acceptable
            IF format('%s.%s', tbl.table_name, col.column_name) = ANY (ignored_columns) THEN
                CONTINUE;
            END IF;

            EXECUTE format(
                'SELECT COUNT(*) FROM silver.%I WHERE %I IS NULL',
                tbl.table_name,
                col.column_name
            )
            INTO null_count;

            IF null_count > 0 THEN
                has_nulls := TRUE;
                any_nulls := TRUE;

                RAISE NOTICE '  Column: % | NULLs: %',
                    col.column_name,
                    null_count;

                fail_msg := fail_msg || format(
                    '%s.%s (%s NULLs); ',
                    tbl.table_name,
                    col.column_name,
                    null_count
                );
            END IF;
        END LOOP;

        IF NOT has_nulls THEN
            RAISE NOTICE '  ✓ No unexpected NULL values found.';
        END IF;
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'NULL Check Complete';
    RAISE NOTICE '========================================';

    IF any_nulls THEN
        RAISE EXCEPTION 'NULL check FAILED: %', fail_msg;
    ELSE
        RAISE NOTICE '✓ All Silver tables passed NULL validation.';
    END IF;

END $$;
