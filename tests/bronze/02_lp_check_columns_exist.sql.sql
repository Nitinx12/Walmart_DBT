/*
===============================================================================
 Script Name : 02_lp_check_columns_exist.sql
 Description : Check that every Bronze table has at least one column.
===============================================================================
*/

DO $$
DECLARE
    tbl RECORD;
    column_count INT;
    any_failed BOOLEAN := FALSE;
    fail_msg TEXT := '';
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Checking Bronze Table Columns';
    RAISE NOTICE '========================================';

    FOR tbl IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'bronze'
          AND table_type = 'BASE TABLE'
          AND table_name NOT IN ('etl_logs','etl_watermarks')
        ORDER BY table_name
    LOOP

        SELECT COUNT(*)
        INTO column_count
        FROM information_schema.columns
        WHERE table_schema = 'bronze'
          AND table_name = tbl.table_name;

        IF column_count = 0 THEN

            any_failed := TRUE;

            RAISE NOTICE
                '✗ Table: % | No columns found.',
                tbl.table_name;

            fail_msg := fail_msg || tbl.table_name || '; ';

        ELSE

            RAISE NOTICE
                '✓ Table: % | Columns: %',
                tbl.table_name,
                column_count;

        END IF;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Column Check Complete';
    RAISE NOTICE '========================================';

    IF any_failed THEN
        RAISE EXCEPTION
            'Tables with missing columns: %',
            fail_msg;
    ELSE
        RAISE NOTICE
            '✓ All Bronze tables contain columns.';
    END IF;

END $$;
