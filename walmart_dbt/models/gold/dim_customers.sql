{{ config(
    materialized='incremental',
    unique_key='customer_id',
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

WITH source_customers AS (

    SELECT
        customer_id,
        customer_name,
        phone,
        phone_extension,
        email,
        is_active,
        city,
        province,
        country,
        created_timestamp,
        updated_timestamp
    FROM {{ ref('customers') }}

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
    customer_id,
    customer_name,
    phone,
    phone_extension,
    email,
    is_active,
    city,
    province,
    country,
    created_timestamp,
    updated_timestamp,
    CURRENT_TIMESTAMP AS gold_loaded_at
FROM source_customers