/*
===============================================================================
 Script Name : 09_lp_check_unwanted_spaces.sql
 Description : Check all text columns in the silver schema for
               leading spaces, trailing spaces, and multiple spaces.
===============================================================================
*/

DO $$
DECLARE
    tbl RECORD;
    col RECORD;
    invalid_count BIGINT;
    has_spaces BOOLEAN;
    any_spaces BOOLEAN := FALSE;
    fail_msg TEXT := '';
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Checking Unwanted Spaces in Silver Schema';
    RAISE NOTICE '========================================';

    FOR tbl IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'silver'
          AND table_type = 'BASE TABLE'
        ORDER BY table_name
    LOOP
        has_spaces := FALSE;

        RAISE NOTICE '';
        RAISE NOTICE 'Table: %', tbl.table_name;

        FOR col IN
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = 'silver'
              AND table_name = tbl.table_name
              AND data_type IN (
                    'text',
                    'character varying',
                    'character'
              )
            ORDER BY ordinal_position
        LOOP

            EXECUTE format(
                'SELECT COUNT(*)
                 FROM silver.%I
                 WHERE %I IS NOT NULL
                   AND (
                        %I <> BTRIM(%I)
                        OR %I ~ '' {2,}''
                   )',
                tbl.table_name,
                col.column_name,
                col.column_name,
                col.column_name,
                col.column_name
            )
            INTO invalid_count;

            IF invalid_count > 0 THEN
                has_spaces := TRUE;
                any_spaces := TRUE;

                RAISE NOTICE
                    '  Column: % | Rows with unwanted spaces: %',
                    col.column_name,
                    invalid_count;

                fail_msg := fail_msg || format(
                    '%s.%s (%s rows); ',
                    tbl.table_name,
                    col.column_name,
                    invalid_count
                );
            END IF;

        END LOOP;

        IF NOT has_spaces THEN
            RAISE NOTICE '  ✓ No unwanted spaces found.';
        END IF;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Unwanted Spaces Check Complete';
    RAISE NOTICE '========================================';

    IF any_spaces THEN
        RAISE EXCEPTION
            'Unwanted spaces check FAILED: %',
            fail_msg;
    ELSE
        RAISE NOTICE
            '✓ All Silver tables passed unwanted spaces validation.';
    END IF;

END $$;
