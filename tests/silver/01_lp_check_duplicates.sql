/*
===============================================================================
 Script Name : silver_check_duplicates.sql
 Description : Validate all Silver tables.
               - Count rows.
               - Check duplicate values in the first column (usually PK).
               - Print "No duplicate values found." when applicable.
===============================================================================
*/

DO $$
DECLARE
    tbl RECORD;
    pk_col TEXT;
    row_count BIGINT;
    duplicate_count BIGINT;
    has_duplicates BOOLEAN;
    any_duplicates BOOLEAN := FALSE;
    fail_msg TEXT := '';
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Starting Silver Duplicate Check';
    RAISE NOTICE '========================================';

    FOR tbl IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'silver'
          AND table_type = 'BASE TABLE'
        ORDER BY table_name
    LOOP
        has_duplicates := FALSE;

        -- Count rows
        EXECUTE format(
            'SELECT COUNT(*) FROM silver.%I',
            tbl.table_name
        )
        INTO row_count;

        RAISE NOTICE '';
        RAISE NOTICE 'Table : %', tbl.table_name;
        RAISE NOTICE 'Rows  : %', row_count;

        -- First column (normally the business key)
        SELECT column_name
        INTO pk_col
        FROM information_schema.columns
        WHERE table_schema = 'silver'
          AND table_name = tbl.table_name
        ORDER BY ordinal_position
        LIMIT 1;

        EXECUTE format(
            'SELECT COUNT(*) FROM (
                SELECT %I
                FROM silver.%I
                GROUP BY %I
                HAVING COUNT(*) > 1
            ) x',
            pk_col,
            tbl.table_name,
            pk_col
        )
        INTO duplicate_count;

        IF duplicate_count > 0 THEN
            has_duplicates := TRUE;
            any_duplicates := TRUE;

            RAISE NOTICE '  Duplicate Keys -> % : %',
                pk_col,
                duplicate_count;

            fail_msg := fail_msg || format(
                '%s.%s (%s duplicate values); ',
                tbl.table_name,
                pk_col,
                duplicate_count
            );
        END IF;

        IF NOT has_duplicates THEN
            RAISE NOTICE '  ✓ No duplicate values found.';
        END IF;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Silver Duplicate Check Complete';
    RAISE NOTICE '========================================';

    IF any_duplicates THEN
        RAISE EXCEPTION 'Silver duplicate check FAILED: %', fail_msg;
    END IF;

END $$;
