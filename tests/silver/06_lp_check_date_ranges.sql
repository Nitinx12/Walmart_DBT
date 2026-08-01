/*
===============================================================================
 Script Name : 06_lp_check_date_ranges.sql
 Description : Check all date/timestamp columns in the silver schema for
               values outside the allowed date range.
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

    min_date DATE := DATE '2000-01-01';
    max_date DATE := CURRENT_DATE + INTERVAL '1 year';
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Checking Date Ranges in Silver Schema';
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
                    'date',
                    'timestamp without time zone',
                    'timestamp with time zone'
              )
            ORDER BY ordinal_position
        LOOP

            EXECUTE format(
                'SELECT COUNT(*)
                 FROM silver.%I
                 WHERE %I IS NOT NULL
                   AND (%I::date < %L OR %I::date > %L)',
                tbl.table_name,
                col.column_name,
                col.column_name,
                min_date,
                col.column_name,
                max_date
            )
            INTO invalid_count;

            IF invalid_count > 0 THEN
                has_invalid := TRUE;
                any_invalid := TRUE;

                RAISE NOTICE
                    '  Column: % | Out-of-range Dates: %',
                    col.column_name,
                    invalid_count;

                fail_msg := fail_msg || format(
                    '%s.%s (%s invalid dates); ',
                    tbl.table_name,
                    col.column_name,
                    invalid_count
                );
            END IF;

        END LOOP;

        IF NOT has_invalid THEN
            RAISE NOTICE '  ✓ All date values are within range.';
        END IF;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Date Range Check Complete';
    RAISE NOTICE '========================================';

    IF any_invalid THEN
        RAISE EXCEPTION 'Date range check FAILED: %', fail_msg;
    ELSE
        RAISE NOTICE '✓ All Silver tables passed date range validation.';
    END IF;

END $$;