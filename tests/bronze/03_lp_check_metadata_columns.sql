/*
===============================================================================
 Script Name : 03_lp_check_metadata_columns.sql
 Description : Validate metadata columns in Bronze tables.
               - Required metadata columns exist.
               - _id is NOT NULL.
               - _id is UNIQUE.
               - created_timestamp is NOT NULL.
               - updated_timestamp is NOT NULL.
               - is_active is NOT NULL.
===============================================================================
*/

DO $$
DECLARE
    tbl RECORD;
    metadata_col TEXT;
    invalid_count BIGINT;
    duplicate_count BIGINT;
    any_failed BOOLEAN := FALSE;
    fail_msg TEXT := '';
BEGIN

    RAISE NOTICE '========================================';
    RAISE NOTICE 'Checking Bronze Metadata Columns';
    RAISE NOTICE '========================================';

    FOR tbl IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'bronze'
          AND table_type = 'BASE TABLE'
          AND table_name NOT IN ('etl_logs','etl_watermarks')
        ORDER BY table_name
    LOOP

        RAISE NOTICE '';
        RAISE NOTICE 'Table: %', tbl.table_name;

        --------------------------------------------------------------------
        -- Check required metadata columns
        --------------------------------------------------------------------

        FOREACH metadata_col IN ARRAY ARRAY[
            '_id',
            'created_timestamp',
            'updated_timestamp',
            'is_active'
        ]
        LOOP

            IF EXISTS (
                SELECT 1
                FROM information_schema.columns
                WHERE table_schema='bronze'
                  AND table_name=tbl.table_name
                  AND column_name=metadata_col
            ) THEN

                RAISE NOTICE '  ✓ Column % exists.', metadata_col;

            ELSE

                any_failed := TRUE;

                RAISE NOTICE '  ✗ Missing column: %', metadata_col;

                fail_msg := fail_msg || format(
                    '%s missing %s; ',
                    tbl.table_name,
                    metadata_col
                );

            END IF;

        END LOOP;

        --------------------------------------------------------------------
        -- _id NOT NULL
        --------------------------------------------------------------------

        IF EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema='bronze'
              AND table_name=tbl.table_name
              AND column_name='_id'
        ) THEN

            EXECUTE format(
                'SELECT COUNT(*)
                 FROM bronze.%I
                 WHERE _id IS NULL',
                tbl.table_name
            )
            INTO invalid_count;

            IF invalid_count > 0 THEN

                any_failed := TRUE;

                RAISE NOTICE
                    '  ✗ _id contains % NULL values.',
                    invalid_count;

                fail_msg := fail_msg || format(
                    '%s _id NULL; ',
                    tbl.table_name
                );

            ELSE

                RAISE NOTICE
                    '  ✓ _id contains no NULL values.';

            END IF;

            ----------------------------------------------------------------
            -- _id UNIQUE
            ----------------------------------------------------------------

            EXECUTE format(
                'SELECT COUNT(*)
                 FROM (
                     SELECT _id
                     FROM bronze.%I
                     GROUP BY _id
                     HAVING COUNT(*) > 1
                 ) x',
                tbl.table_name
            )
            INTO duplicate_count;

            IF duplicate_count > 0 THEN

                any_failed := TRUE;

                RAISE NOTICE
                    '  ✗ Duplicate _id values: %',
                    duplicate_count;

                fail_msg := fail_msg || format(
                    '%s duplicate _id; ',
                    tbl.table_name
                );

            ELSE

                RAISE NOTICE
                    '  ✓ _id is unique.';

            END IF;

        END IF;

        --------------------------------------------------------------------
        -- created_timestamp NOT NULL
        --------------------------------------------------------------------

        IF EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema='bronze'
              AND table_name=tbl.table_name
              AND column_name='created_timestamp'
        ) THEN

            EXECUTE format(
                'SELECT COUNT(*)
                 FROM bronze.%I
                 WHERE created_timestamp IS NULL',
                tbl.table_name
            )
            INTO invalid_count;

            IF invalid_count > 0 THEN

                any_failed := TRUE;

                RAISE NOTICE
                    '  ✗ created_timestamp NULLs: %',
                    invalid_count;

            ELSE

                RAISE NOTICE
                    '  ✓ created_timestamp passed.';

            END IF;

        END IF;

        --------------------------------------------------------------------
        -- updated_timestamp NOT NULL
        --------------------------------------------------------------------

        IF EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema='bronze'
              AND table_name=tbl.table_name
              AND column_name='updated_timestamp'
        ) THEN

            EXECUTE format(
                'SELECT COUNT(*)
                 FROM bronze.%I
                 WHERE updated_timestamp IS NULL',
                tbl.table_name
            )
            INTO invalid_count;

            IF invalid_count > 0 THEN

                any_failed := TRUE;

                RAISE NOTICE
                    '  ✗ updated_timestamp NULLs: %',
                    invalid_count;

            ELSE

                RAISE NOTICE
                    '  ✓ updated_timestamp passed.';

            END IF;

        END IF;

        --------------------------------------------------------------------
        -- is_active NOT NULL
        --------------------------------------------------------------------

        IF EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema='bronze'
              AND table_name=tbl.table_name
              AND column_name='is_active'
        ) THEN

            EXECUTE format(
                'SELECT COUNT(*)
                 FROM bronze.%I
                 WHERE is_active IS NULL',
                tbl.table_name
            )
            INTO invalid_count;

            IF invalid_count > 0 THEN

                any_failed := TRUE;

                RAISE NOTICE
                    '  ✗ is_active NULLs: %',
                    invalid_count;

            ELSE

                RAISE NOTICE
                    '  ✓ is_active passed.';

            END IF;

        END IF;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Metadata Validation Complete';
    RAISE NOTICE '========================================';

    IF any_failed THEN
        RAISE EXCEPTION
            'Metadata validation FAILED: %',
            fail_msg;
    ELSE
        RAISE NOTICE
            '✓ All Bronze metadata checks passed.';
    END IF;

END $$;
