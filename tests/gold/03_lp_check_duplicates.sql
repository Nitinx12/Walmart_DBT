/*
===============================================================================
 Script Name : 03_lp__check_duplicates.sql
 Description : Validate duplicate primary keys in Gold schema.
               - Detects the primary key of each table.
               - Checks for duplicate PK values.
===============================================================================
*/

DO $$
DECLARE
    tbl RECORD;
    pk_cols TEXT;
    dup_count BIGINT;
    failed_tables TEXT := '';
    has_duplicates BOOLEAN := FALSE;
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Starting Gold Duplicate Check';
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

        -- Get Primary Key Columns
        SELECT string_agg(quote_ident(kcu.column_name), ', ' ORDER BY kcu.ordinal_position)
        INTO pk_cols
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name
         AND tc.table_schema = kcu.table_schema
        WHERE tc.constraint_type = 'PRIMARY KEY'
          AND tc.table_schema = 'gold'
          AND tc.table_name = tbl.table_name;

        -- Skip if no primary key exists
        IF pk_cols IS NULL THEN
            RAISE NOTICE '  ⚠ No primary key found. Skipping.';
            CONTINUE;
        END IF;

        EXECUTE format(
            'SELECT COUNT(*)
             FROM (
                 SELECT %s
                 FROM gold.%I
                 GROUP BY %s
                 HAVING COUNT(*) > 1
             ) d',
             pk_cols,
             tbl.table_name,
             pk_cols
        )
        INTO dup_count;

        IF dup_count > 0 THEN
            has_duplicates := TRUE;

            failed_tables := failed_tables ||
                             format('%s (%s duplicate key(s)); ',
                                    tbl.table_name,
                                    dup_count);

            RAISE NOTICE '  ✗ % duplicate key(s) found.', dup_count;
        ELSE
            RAISE NOTICE '  ✓ No duplicate keys found.';
        END IF;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Gold Duplicate Check Complete';
    RAISE NOTICE '========================================';

    IF has_duplicates THEN
        RAISE EXCEPTION 'Gold duplicate check FAILED: %', failed_tables;
    END IF;

END $$;