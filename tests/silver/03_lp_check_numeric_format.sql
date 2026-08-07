/*
===============================================================================
 Script Name : 03_lp_check_numeric_columns.sql
 Description : Validate that all numeric columns contain valid numeric values.
               (Useful mainly as a sanity check.)
===============================================================================
*/

DO $$
DECLARE
    tbl RECORD;
    col RECORD;
    invalid_count BIGINT;
    has_invalid BOOLEAN;
    any_invalid BOOLEAN := FALSE;
    fail_msg TEXT := '';
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Checking Numeric Columns';
    RAISE NOTICE '========================================';

    FOR tbl IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'silver'
          AND table_type = 'BASE TABLE'
        ORDER BY table_name
    LOOP
        has_invalid := FALSE;

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
                $sql$
                SELECT COUNT(*)
                FROM silver.%I
                WHERE %I IS NOT NULL
                  AND %I::text !~ '^-?[0-9]+(\.[0-9]+)?$'
                $sql$,
                tbl.table_name,
                col.column_name,
                col.column_name
            )
            INTO invalid_count;

            IF invalid_count > 0 THEN
                has_invalid := TRUE;
                any_invalid := TRUE;

                RAISE NOTICE
                    '  Column: % | Invalid Values: %',
                    col.column_name,
                    invalid_count;

                fail_msg := fail_msg || format(
                    '%s.%s (%s invalid values); ',
                    tbl.table_name,
                    col.column_name,
                    invalid_count
                );
            END IF;

        END LOOP;

        IF NOT has_invalid THEN
            RAISE NOTICE '  ✓ All numeric columns are valid.';
        END IF;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Numeric Check Complete';
    RAISE NOTICE '========================================';

    IF any_invalid THEN
        RAISE EXCEPTION 'Numeric validation FAILED: %', fail_msg;
    ELSE
        RAISE NOTICE '✓ All numeric columns passed validation.';
    END IF;

END $$;
