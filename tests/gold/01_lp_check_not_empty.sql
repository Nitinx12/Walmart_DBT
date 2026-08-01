/*
===============================================================================
 Script Name : 01_lp_check_not_empty.sql
 Description : Validate all Gold tables.
               - Count rows.
               - Fail if any Gold table is empty.
===============================================================================
*/

DO $$
DECLARE
    tbl RECORD;
    row_count BIGINT;
    any_empty BOOLEAN := FALSE;
    fail_msg TEXT := '';
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Starting Gold Empty Table Check';
    RAISE NOTICE '========================================';

    FOR tbl IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'gold'
          AND table_type = 'BASE TABLE'
        ORDER BY table_name
    LOOP

        EXECUTE format(
            'SELECT COUNT(*) FROM gold.%I',
            tbl.table_name
        )
        INTO row_count;

        RAISE NOTICE '';
        RAISE NOTICE 'Table : %', tbl.table_name;
        RAISE NOTICE 'Rows  : %', row_count;

        IF row_count = 0 THEN
            any_empty := TRUE;

            RAISE NOTICE '  ✗ Table is empty.';

            fail_msg := fail_msg || format(
                '%s (0 rows); ',
                tbl.table_name
            );
        ELSE
            RAISE NOTICE '  ✓ Table contains data.';
        END IF;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Gold Empty Table Check Complete';
    RAISE NOTICE '========================================';

    IF any_empty THEN
        RAISE EXCEPTION 'Gold empty table check FAILED: %', fail_msg;
    END IF;

END $$;