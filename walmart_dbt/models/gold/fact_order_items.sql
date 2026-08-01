{{ config(
    materialized='incremental',
    unique_key='order_item_id',
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

-- Grain: one row per order line item. FKs to dim_orders (order_id) and
-- dim_products (product_id).

WITH source_order_items AS (

    SELECT
        order_item_id,
        order_id,
        product_id,
        is_active,
        quantity,
        unit_price,
        line_amount,
        created_timestamp,
        updated_timestamp
    FROM {{ ref('order_items') }}

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
    order_item_id,
    order_id,
    product_id,
    is_active,
    quantity,
    unit_price,
    line_amount,
    created_timestamp,
    updated_timestamp,
    CURRENT_TIMESTAMP AS gold_loaded_at
FROM source_order_items