/*
===============================================================================
Script Name : Gold Layer - Unwanted Spaces Validation
Schema      : gold
Purpose     : Validate all string columns in the Gold schema for
              unwanted spaces.

Checks Performed:
    1. Leading spaces
    2. Trailing spaces
    3. Multiple consecutive spaces

Behavior:
    - Automatically scans every text/varchar/char column.
    - Raises an EXCEPTION immediately if unwanted spaces are found.
    - Prints PASS message for each validated column.

Author      : Nitin
===============================================================================
*/

DO $$
DECLARE
    rec RECORD;

    v_bad_count BIGINT;

BEGIN

    RAISE NOTICE '============================================================';
    RAISE NOTICE 'Starting Gold Unwanted Spaces Validation';
    RAISE NOTICE '============================================================';

    ---------------------------------------------------------------------------
    -- Loop through every character column in Gold schema
    ---------------------------------------------------------------------------
    FOR rec IN
        SELECT
            table_name,
            column_name
        FROM information_schema.columns
        WHERE table_schema = 'gold'
          AND data_type IN (
                'character varying',
                'character',
                'text'
          )
        ORDER BY table_name, ordinal_position
    LOOP

        -----------------------------------------------------------------------
        -- Count values with leading, trailing or multiple spaces
        -----------------------------------------------------------------------
        EXECUTE format(
            'SELECT COUNT(*)
             FROM gold.%I
             WHERE %I IS NOT NULL
               AND (
                    %I <> BTRIM(%I)
                    OR %I ~ '' {2,}''
               )',
            rec.table_name,
            rec.column_name,
            rec.column_name,
            rec.column_name,
            rec.column_name
        )
        INTO v_bad_count;

        -----------------------------------------------------------------------
        -- Validation
        -----------------------------------------------------------------------
        IF v_bad_count > 0 THEN
            RAISE EXCEPTION
                'FAILED -> %.% contains % value(s) with unwanted spaces.',
                rec.table_name,
                rec.column_name,
                v_bad_count;
        END IF;

        -----------------------------------------------------------------------
        -- Success Message
        -----------------------------------------------------------------------
        RAISE NOTICE
            'PASS -> %.% : No unwanted spaces.',
            rec.table_name,
            rec.column_name;

    END LOOP;

    ---------------------------------------------------------------------------
    -- Validation Completed
    -----------------------------------------------------------------------
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'SUCCESS: All Gold string columns passed unwanted spaces validation.';
    RAISE NOTICE '============================================================';

END;
$$;