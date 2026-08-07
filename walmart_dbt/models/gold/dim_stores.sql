{{ config(
    materialized='incremental',
    unique_key='store_id',
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

WITH source_stores AS (

    SELECT
        ss.store_id,
        ss.store_name,
        ss.city,
        ss.province,
        ss.country,
        ss.is_active,
        ss.created_timestamp,
        ss.updated_timestamp
    FROM {{ ref('stores') }} AS ss

    {% if is_incremental() %}
        WHERE ss.updated_timestamp >= (
            COALESCE(
                (SELECT MAX(t.updated_timestamp) FROM {{ this }} AS t),
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
