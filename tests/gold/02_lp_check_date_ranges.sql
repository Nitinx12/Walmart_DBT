/*
===============================================================================
 Script Name : 02_gp_check_date_ranges.sql
 Description : Validate date/timestamp columns in Gold schema.
               - No dates before 2000-01-01.
               - No future dates.
===============================================================================
*/

DO $$
DECLARE
    tbl RECORD;
    col RECORD;
    min_date TIMESTAMP;
    max_date TIMESTAMP;
    invalid_past BIGINT;
    invalid_future BIGINT;

    min_allowed CONSTANT TIMESTAMP := '2000-01-01';
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Starting Gold Date Range Check';
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
              AND data_type IN ('date',
                                'timestamp without time zone',
                                'timestamp with time zone')
        LOOP

            EXECUTE format(
                'SELECT
                    MIN(%1$I),
                    MAX(%1$I),
                    COUNT(*) FILTER (WHERE %1$I < $1),
                    COUNT(*) FILTER (WHERE %1$I > CURRENT_TIMESTAMP)
                 FROM gold.%2$I',
                 col.column_name,
                 tbl.table_name
            )
            INTO min_date,
                 max_date,
                 invalid_past,
                 invalid_future
            USING min_allowed;

            RAISE NOTICE '  Column: %', col.column_name;
            RAISE NOTICE '     Min Value : %', COALESCE(min_date::TEXT, 'NULL');
            RAISE NOTICE '     Max Value : %', COALESCE(max_date::TEXT, 'NULL');

            IF invalid_past > 0 THEN
                RAISE NOTICE '     ✗ % record(s) before %',
                    invalid_past,
                    min_allowed::DATE;
            END IF;

            IF invalid_future > 0 THEN
                RAISE NOTICE '     ✗ % future record(s)',
                    invalid_future;
            END IF;

            IF invalid_past = 0 AND invalid_future = 0 THEN
                RAISE NOTICE '     ✓ Date range valid';
            END IF;

        END LOOP;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Gold Date Range Check Complete';
    RAISE NOTICE '========================================';

END $$;