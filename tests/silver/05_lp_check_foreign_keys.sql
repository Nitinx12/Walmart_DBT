/*
===============================================================================
 Script Name : 06_lp_check_foreign_keys.sql
 Description : Check all foreign key relationships in the silver schema for
               orphan records.
===============================================================================
*/

DO $$
DECLARE
    fk RECORD;
    orphan_count BIGINT;
    has_orphans BOOLEAN := FALSE;
    fail_msg TEXT := '';
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Checking Foreign Key Integrity';
    RAISE NOTICE '========================================';

    FOR fk IN
        SELECT
            tc.table_name AS child_table,
            kcu.column_name AS child_column,
            ccu.table_name AS parent_table,
            ccu.column_name AS parent_column
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name
         AND tc.table_schema = kcu.table_schema
        JOIN information_schema.constraint_column_usage ccu
          ON tc.constraint_name = ccu.constraint_name
         AND tc.table_schema = ccu.table_schema
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND tc.table_schema = 'silver'
        ORDER BY tc.table_name
    LOOP

        EXECUTE format(
            'SELECT COUNT(*)
             FROM silver.%I c
             LEFT JOIN silver.%I p
               ON c.%I = p.%I
             WHERE c.%I IS NOT NULL
               AND p.%I IS NULL',
            fk.child_table,
            fk.parent_table,
            fk.child_column,
            fk.parent_column,
            fk.child_column,
            fk.parent_column
        )
        INTO orphan_count;

        IF orphan_count > 0 THEN
            has_orphans := TRUE;

            RAISE NOTICE
                'Child: %.% -> Parent: %.% | Orphans: %',
                fk.child_table,
                fk.child_column,
                fk.parent_table,
                fk.parent_column,
                orphan_count;

            fail_msg := fail_msg || format(
                '%s.%s -> %s.%s (%s orphan rows); ',
                fk.child_table,
                fk.child_column,
                fk.parent_table,
                fk.parent_column,
                orphan_count
            );
        ELSE
            RAISE NOTICE
                '✓ %.% -> %.%',
                fk.child_table,
                fk.child_column,
                fk.parent_table,
                fk.parent_column;
        END IF;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Foreign Key Check Complete';
    RAISE NOTICE '========================================';

    IF has_orphans THEN
        RAISE EXCEPTION
            'Foreign key validation FAILED: %',
            fail_msg;
    ELSE
        RAISE NOTICE
            '✓ All foreign key relationships are valid.';
    END IF;

END $$;
