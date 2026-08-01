/*
===============================================================================
 Script Name : 04_lp_check_negative_values.sql
 Description : Validate numeric columns in Gold schema.
               - Checks for negative values.
===============================================================================
*/

DO $$
DECLARE
    tbl RECORD;
    col RECORD;
    negative_count BIGINT;
    failed_columns TEXT := '';
    has_negative BOOLEAN := FALSE;
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Starting Gold Negative Value Check';
    RAISE NOTICE '========================================';

    FOR tbl IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'gold'
          AND table_type = 'BASE TABLE'
        ORDER BY table_name
    LOOP

        RAISE NOTICE '';
        RAISE NOTICE 'Table: %', tbl.table_name;

        FOR col IN
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = 'gold'
              AND table_name = tbl.table_name
              AND data_type IN
              (
                  'smallint',
                  'integer',
                  'bigint',
                  'numeric',
                  'decimal',
                  'real',
                  'double precision'
              )
        LOOP

            EXECUTE format(
                'SELECT COUNT(*)
                 FROM gold.%I
                 WHERE %I < 0',
                 tbl.table_name,
                 col.column_name
            )
            INTO negative_count;

            IF negative_count > 0 THEN

                has_negative := TRUE;

                failed_columns := failed_columns ||
                    format('%s.%s (%s negatives); ',
                           tbl.table_name,
                           col.column_name,
                           negative_count);

                RAISE NOTICE '  ✗ Column: % --> % negative value(s)',
                    col.column_name,
                    negative_count;

            ELSE

                RAISE NOTICE '  ✓ Column: %', col.column_name;

            END IF;

        END LOOP;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Gold Negative Value Check Complete';
    RAISE NOTICE '========================================';

    IF has_negative THEN
        RAISE EXCEPTION
        'Negative value check FAILED: %',
        failed_columns;
    END IF;

END $$;