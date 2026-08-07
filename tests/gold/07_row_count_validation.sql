/*
===============================================================================
Script Name : Gold Layer - Silver vs Gold Row Count Validation
Schema      : silver, gold
Purpose     : Validate that every Gold table contains the expected number of
              rows from its corresponding Silver source table.

Checks Performed:
    1. Compare Silver and Gold row counts.
    2. Raise EXCEPTION if counts do not match.
    3. Print PASS message if counts match.

Notes:
    - Only compares tables that have a true 1:1 relationship.
    - Fact tables created from aggregations should NOT be included unless
      they are expected to have identical row counts.

Author      : Nitin
===============================================================================
*/

DO
$$
DECLARE
    rec RECORD;

    v_silver_count BIGINT;
    v_gold_count   BIGINT;

BEGIN

    RAISE NOTICE '===========================================================';
    RAISE NOTICE 'Starting Silver vs Gold Row Count Validation';
    RAISE NOTICE '===========================================================';

    ---------------------------------------------------------------------------
    -- Table Mapping (Silver -> Gold)
    ---------------------------------------------------------------------------
    FOR rec IN

        SELECT *
        FROM (
            VALUES
                ('brands',           'dim_brands'),
                ('categories',       'dim_categories'),
                ('customers',        'dim_customers'),
                ('orders',           'dim_orders'),
                ('payment_methods',  'dim_payment_methods'),
                ('products',         'dim_products'),
                ('stores',           'dim_stores'),
                ('order_items',      'fact_order_items')
        ) AS mapping(silver_table, gold_table)

    LOOP

        -----------------------------------------------------------------------
        -- Get Silver Row Count
        -----------------------------------------------------------------------
        EXECUTE format(
            'SELECT COUNT(*) FROM silver.%I',
            rec.silver_table
        )
        INTO v_silver_count;

        -----------------------------------------------------------------------
        -- Get Gold Row Count
        -----------------------------------------------------------------------
        EXECUTE format(
            'SELECT COUNT(*) FROM gold.%I',
            rec.gold_table
        )
        INTO v_gold_count;

        -----------------------------------------------------------------------
        -- Compare Row Counts
        -----------------------------------------------------------------------
        IF v_silver_count <> v_gold_count THEN

            RAISE EXCEPTION
                'FAILED -> silver.% has % rows, but gold.% has % rows.',
                rec.silver_table,
                v_silver_count,
                rec.gold_table,
                v_gold_count;

        END IF;

        -----------------------------------------------------------------------
        -- PASS
        -----------------------------------------------------------------------
        RAISE NOTICE
            'PASS -> silver.% (%) = gold.% (%)',
            rec.silver_table,
            v_silver_count,
            rec.gold_table,
            v_gold_count;

    END LOOP;

    ---------------------------------------------------------------------------
    -- Validation Completed
    ---------------------------------------------------------------------------
    RAISE NOTICE '===========================================================';
    RAISE NOTICE 'SUCCESS: All mapped Silver and Gold row counts match.';
    RAISE NOTICE '===========================================================';

END;
$$;
