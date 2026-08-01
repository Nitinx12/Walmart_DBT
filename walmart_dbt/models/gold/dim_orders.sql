{{ config(
    materialized='incremental',
    unique_key='order_id',
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

-- Fully normalized: store_id / customer_id / payment_method_id are FKs to
-- their own dimension tables (dim_stores / dim_customers /
-- dim_payment_methods). No denormalized names in here.

WITH source_orders AS (

    SELECT
        order_id,
        store_id,
        customer_id,
        payment_method_id,
        order_status,
        is_active,
        total_amount,
        order_timestamp,
        created_timestamp,
        updated_timestamp
    FROM {{ ref('orders') }}

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
    order_id,
    store_id,
    customer_id,
    payment_method_id,
    order_status,
    is_active,
    total_amount,
    order_timestamp,
    created_timestamp,
    updated_timestamp,
    CURRENT_TIMESTAMP AS gold_loaded_at
FROM source_orders