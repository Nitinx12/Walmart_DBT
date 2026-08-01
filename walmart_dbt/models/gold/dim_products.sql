{{ config(
    materialized='incremental',
    unique_key='product_id',
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

-- Fully normalized: brand_id / category_id are FKs to their own dimension
-- tables (dim_brands / dim_categories). No denormalized names in here.

WITH source_products AS (

    SELECT
        product_id,
        product_name,
        brand_id,
        category_id,
        is_active,
        price,
        created_timestamp,
        updated_timestamp
    FROM {{ ref('products') }}

    {% if is_incremental() %}
    WHERE updated_timestamp >= (
        COALESCE(
            (SELECT MAX(updated_timestamp) FROM {{ this }}),
            TIMESTAMP '1900-01-01'
        ) - INTERVAL '3 days'
    )
    {% endif %}

)

SELECT
    product_id,
    product_name,
    brand_id,
    category_id,
    is_active,
    price,
    created_timestamp,
    updated_timestamp,
    CURRENT_TIMESTAMP AS gold_loaded_at
FROM source_products