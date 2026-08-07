{{ config(
    materialized='incremental',
    unique_key='customer_id',
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

WITH source_customers AS (

    SELECT
        sc.customer_id,
        sc.customer_name,
        sc.phone,
        sc.phone_extension,
        sc.email,
        sc.is_active,
        sc.city,
        sc.province,
        sc.country,
        sc.created_timestamp,
        sc.updated_timestamp
    FROM {{ ref('customers') }} AS sc

    {% if is_incremental() %}
        WHERE sc.updated_timestamp >= (
            COALESCE(
                (SELECT MAX(t.updated_timestamp) FROM {{ this }} AS t),
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
