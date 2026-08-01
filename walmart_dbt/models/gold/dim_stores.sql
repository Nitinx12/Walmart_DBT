{{ config(
    materialized='incremental',
    unique_key='store_id',
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

WITH source_stores AS (

    SELECT
        store_id,
        store_name,
        city,
        province,
        country,
        is_active,
        created_timestamp,
        updated_timestamp
    FROM {{ ref('stores') }}

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
    store_id,
    store_name,
    city,
    province,
    country,
    is_active,
    created_timestamp,
    updated_timestamp,
    CURRENT_TIMESTAMP AS gold_loaded_at
FROM source_stores