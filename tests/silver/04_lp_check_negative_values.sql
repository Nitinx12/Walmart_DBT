/*
===============================================================================
 Script Name : 04_lp_check_negative_values.sql
 Description : Check all numeric columns in the silver schema for negative values.
===============================================================================
*/

DO $$
DECLARE
    tbl RECORD;
    col RECORD;
    negative_count BIGINT;
    has_negative BOOLEAN;
    any_negative BOOLEAN := FALSE;
    fail_msg TEXT := '';
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Checking Negative Values in Silver Schema';
    RAISE NOTICE '========================================';

    FOR tbl IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'silver'
          AND table_type = 'BASE TABLE'
        ORDER BY table_name
    LOOP
        has_negative := FALSE;

        RAISE NOTICE '';
        RAISE NOTICE 'Table: %', tbl.table_name;

        FOR col IN
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = 'silver'
              AND table_name = tbl.table_name
              AND data_type IN (
                    'smallint',
                    'integer',
                    'bigint',
                    'numeric',
                    'decimal',
                    'real',
                    'double precision'
              )
            ORDER BY ordinal_position
        LOOP

            EXECUTE format(
                'SELECT COUNT(*) FROM silver.%I
                 WHERE %I < 0',
                tbl.table_name,
                col.column_name
            )
            INTO negative_count;

            IF negative_count > 0 THEN
                has_negative := TRUE;
                any_negative := TRUE;

                RAISE NOTICE
                    '  Column: % | Negative Values: %',
                    col.column_name,
                    negative_count;

                fail_msg := fail_msg || format(
                    '%s.%s (%s negative values); ',
                    tbl.table_name,
                    col.column_name,
                    negative_count
                );
            END IF;

        END LOOP;

        IF NOT has_negative THEN
            RAISE NOTICE '  ✓ No negative values found.';
        END IF;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Negative Value Check Complete';
    RAISE NOTICE '========================================';

    IF any_negative THEN
        RAISE EXCEPTION 'Negative value check FAILED: %', fail_msg;
    ELSE
        RAISE NOTICE '✓ All Silver tables passed negative value validation.';
    END IF;

END $$;
