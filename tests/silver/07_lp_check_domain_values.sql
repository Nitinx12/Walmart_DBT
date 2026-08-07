/*
===============================================================================
 Script Name : 07_lp_check_domain_values.sql
 Description : Check all configured domain columns in the silver schema
               contain only valid business values.
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
    RAISE NOTICE 'Checking Domain Values in Silver Schema';
    RAISE NOTICE '========================================';

    FOR rule IN
        SELECT *
        FROM (
            VALUES
                (
                    'customers',
                    'country',
                    ARRAY['United States','Canada']
                ),
                (
                    'payment_methods',
                    'payment_method_name',
                    ARRAY['GIFT CARD','CASH','ONLINE','CREDIT CARD','DEBIT CARD']
                ),
                (
                    'orders',
                    'order_status',
                    ARRAY['Completed','Returned','Cancelled','Pending']
                )
        ) AS t(table_name, column_name, allowed_values)
    LOOP

        EXECUTE format(
            'SELECT COUNT(*)
             FROM silver.%I
             WHERE %I IS NOT NULL
               AND NOT (%I = ANY ($1))',
            rule.table_name,
            rule.column_name,
            rule.column_name
        )
        INTO invalid_count
        USING rule.allowed_values;

        IF invalid_count > 0 THEN
            any_invalid := TRUE;

            RAISE NOTICE 'Table: %',
                rule.table_name;

            RAISE NOTICE
                '  Column: % | Invalid Values: %',
                rule.column_name,
                invalid_count;

            fail_msg := fail_msg || format(
                '%s.%s (%s invalid values); ',
                rule.table_name,
                rule.column_name,
                invalid_count
            );
        ELSE
            RAISE NOTICE 'Table: %',
                rule.table_name;

            RAISE NOTICE
                '  ✓ Column % passed.',
                rule.column_name;
        END IF;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Domain Value Check Complete';
    RAISE NOTICE '========================================';

    IF any_invalid THEN
        RAISE EXCEPTION
            'Domain value validation FAILED: %',
            fail_msg;
    ELSE
        RAISE NOTICE
            '✓ All configured domain values are valid.';
    END IF;

END $$;
