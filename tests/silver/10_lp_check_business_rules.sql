/*
===============================================================================
 Script Name : 10_lp_check_business_rules.sql
 Description : Validate business rules in the Silver schema.
===============================================================================
*/

DO $$
DECLARE
    rule RECORD;
    invalid_count BIGINT;
    any_invalid BOOLEAN := FALSE;
    fail_msg TEXT := '';
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Checking Business Rules';
    RAISE NOTICE '========================================';

    FOR rule IN
        SELECT *
        FROM (
            VALUES
                ('order_items', 'Line Amount = Quantity × Unit Price'),
                ('orders',      'Total Amount > 0'),
                ('order_items', 'Quantity > 0'),
                ('order_items', 'Unit Price > 0'),
                ('products',    'Price > 0'),
                ('orders',      'Order Total = Sum of Line Amount')
        ) AS t(table_name, rule_name)
    LOOP

        -----------------------------------------------------------------------
        -- Rule 1
        -----------------------------------------------------------------------
        IF rule.rule_name = 'Line Amount = Quantity × Unit Price' THEN

            SELECT COUNT(*)
            INTO invalid_count
            FROM silver.order_items
            WHERE line_amount <> quantity * unit_price;

        -----------------------------------------------------------------------
        -- Rule 2
        -----------------------------------------------------------------------
        ELSIF rule.rule_name = 'Total Amount > 0' THEN

            SELECT COUNT(*)
            INTO invalid_count
            FROM silver.orders
            WHERE total_amount <= 0;

        -----------------------------------------------------------------------
        -- Rule 3
        -----------------------------------------------------------------------
        ELSIF rule.rule_name = 'Quantity > 0' THEN

            SELECT COUNT(*)
            INTO invalid_count
            FROM silver.order_items
            WHERE quantity <= 0;

        -----------------------------------------------------------------------
        -- Rule 4
        -----------------------------------------------------------------------
        ELSIF rule.rule_name = 'Unit Price > 0' THEN

            SELECT COUNT(*)
            INTO invalid_count
            FROM silver.order_items
            WHERE unit_price <= 0;

        -----------------------------------------------------------------------
        -- Rule 5
        -----------------------------------------------------------------------
        ELSIF rule.rule_name = 'Price > 0' THEN

            SELECT COUNT(*)
            INTO invalid_count
            FROM silver.products
            WHERE price <= 0;

        -----------------------------------------------------------------------
        -- Rule 6
        -----------------------------------------------------------------------
        ELSIF rule.rule_name = 'Order Total = Sum of Line Amount' THEN

            SELECT COUNT(*)
            INTO invalid_count
            FROM (
                SELECT
                    o.order_id
                FROM silver.orders o
                JOIN silver.order_items oi
                    ON o.order_id = oi.order_id
                GROUP BY
                    o.order_id,
                    o.total_amount
                HAVING
                    o.total_amount <> SUM(oi.line_amount)
            ) x;

        END IF;

        -----------------------------------------------------------------------
        -- Print Results
        -----------------------------------------------------------------------
        IF invalid_count > 0 THEN

            any_invalid := TRUE;

            RAISE NOTICE '';
            RAISE NOTICE 'Table: %', rule.table_name;
            RAISE NOTICE '  Rule: %', rule.rule_name;
            RAISE NOTICE '  Failed Rows: %', invalid_count;

            fail_msg := fail_msg || format(
                '%s - %s (%s failed rows); ',
                rule.table_name,
                rule.rule_name,
                invalid_count
            );

        ELSE

            RAISE NOTICE '';
            RAISE NOTICE 'Table: %', rule.table_name;
            RAISE NOTICE '  ✓ % passed.', rule.rule_name;

        END IF;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Business Rule Check Complete';
    RAISE NOTICE '========================================';

    IF any_invalid THEN
        RAISE EXCEPTION 'Business Rule Validation FAILED: %', fail_msg;
    ELSE
        RAISE NOTICE '✓ All business rules passed.';
    END IF;

END $$;