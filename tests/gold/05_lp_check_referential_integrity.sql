/*
===============================================================================
 Script Name : 05_lp_check_referential_integrity.sql
 Description : Validate foreign key relationships in Gold schema.
===============================================================================
*/

DO $$
DECLARE
    missing_count BIGINT;
    has_failed BOOLEAN := FALSE;
BEGIN

    RAISE NOTICE '========================================';
    RAISE NOTICE 'Starting Gold Referential Integrity Check';
    RAISE NOTICE '========================================';

    --------------------------------------------------------------------------
    -- fact_order_items -> dim_orders
    --------------------------------------------------------------------------
    SELECT COUNT(*)
    INTO missing_count
    FROM gold.fact_order_items f
    LEFT JOIN gold.dim_orders o
           ON f.order_id = o.order_id
    WHERE o.order_id IS NULL;

    IF missing_count > 0 THEN
        has_failed := TRUE;
        RAISE NOTICE '✗ order_id : % orphan records', missing_count;
    ELSE
        RAISE NOTICE '✓ order_id';
    END IF;

    --------------------------------------------------------------------------
    -- fact_order_items -> dim_products
    --------------------------------------------------------------------------
    SELECT COUNT(*)
    INTO missing_count
    FROM gold.fact_order_items f
    LEFT JOIN gold.dim_products p
           ON f.product_id = p.product_id
    WHERE p.product_id IS NULL;

    IF missing_count > 0 THEN
        has_failed := TRUE;
        RAISE NOTICE '✗ product_id : % orphan records', missing_count;
    ELSE
        RAISE NOTICE '✓ product_id';
    END IF;

    --------------------------------------------------------------------------
    -- dim_orders -> dim_customers
    --------------------------------------------------------------------------
    SELECT COUNT(*)
    INTO missing_count
    FROM gold.dim_orders o
    LEFT JOIN gold.dim_customers c
           ON o.customer_id = c.customer_id
    WHERE c.customer_id IS NULL;

    IF missing_count > 0 THEN
        has_failed := TRUE;
        RAISE NOTICE '✗ customer_id : % orphan records', missing_count;
    ELSE
        RAISE NOTICE '✓ customer_id';
    END IF;

    --------------------------------------------------------------------------
    -- dim_orders -> dim_stores
    --------------------------------------------------------------------------
    SELECT COUNT(*)
    INTO missing_count
    FROM gold.dim_orders o
    LEFT JOIN gold.dim_stores s
           ON o.store_id = s.store_id
    WHERE s.store_id IS NULL;

    IF missing_count > 0 THEN
        has_failed := TRUE;
        RAISE NOTICE '✗ store_id : % orphan records', missing_count;
    ELSE
        RAISE NOTICE '✓ store_id';
    END IF;

    --------------------------------------------------------------------------
    -- dim_orders -> dim_payment_methods
    --------------------------------------------------------------------------
    SELECT COUNT(*)
    INTO missing_count
    FROM gold.dim_orders o
    LEFT JOIN gold.dim_payment_methods pm
           ON o.payment_method_id = pm.payment_method_id
    WHERE pm.payment_method_id IS NULL;

    IF missing_count > 0 THEN
        has_failed := TRUE;
        RAISE NOTICE '✗ payment_method_id : % orphan records', missing_count;
    ELSE
        RAISE NOTICE '✓ payment_method_id';
    END IF;

    --------------------------------------------------------------------------
    -- dim_products -> dim_brands
    --------------------------------------------------------------------------
    SELECT COUNT(*)
    INTO missing_count
    FROM gold.dim_products p
    LEFT JOIN gold.dim_brands b
           ON p.brand_id = b.brand_id
    WHERE b.brand_id IS NULL;

    IF missing_count > 0 THEN
        has_failed := TRUE;
        RAISE NOTICE '✗ brand_id : % orphan records', missing_count;
    ELSE
        RAISE NOTICE '✓ brand_id';
    END IF;

    --------------------------------------------------------------------------
    -- dim_products -> dim_categories
    --------------------------------------------------------------------------
    SELECT COUNT(*)
    INTO missing_count
    FROM gold.dim_products p
    LEFT JOIN gold.dim_categories c
           ON p.category_id = c.category_id
    WHERE c.category_id IS NULL;

    IF missing_count > 0 THEN
        has_failed := TRUE;
        RAISE NOTICE '✗ category_id : % orphan records', missing_count;
    ELSE
        RAISE NOTICE '✓ category_id';
    END IF;

    --------------------------------------------------------------------------
    -- Final Result
    --------------------------------------------------------------------------
    RAISE NOTICE '========================================';

    IF has_failed THEN
        RAISE EXCEPTION 'Gold referential integrity check FAILED.';
    ELSE
        RAISE NOTICE '✓ All foreign key relationships are valid.';
    END IF;

    RAISE NOTICE '========================================';

END $$;
