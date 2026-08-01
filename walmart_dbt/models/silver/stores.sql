{{ config(
    materialized='incremental',
    unique_key='store_id',
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

WITH incremental_filter AS (
    SELECT
        store_id,
        store_name,
        city,
        province,
        country,
        is_active,
        created_timestamp,
        updated_timestamp,
        _id
    FROM {{ source('bronze', 'stores') }}
    {% if is_incremental() %}
    WHERE updated_timestamp::TIMESTAMP >= (
        COALESCE(
            (SELECT MAX(updated_timestamp::TIMESTAMP) FROM {{ this }}),
            TIMESTAMP '1900-01-01'
        ) - INTERVAL '3 days'
    )
    {% endif %}
),
deduplicated AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY store_id
            ORDER BY
                updated_timestamp DESC NULLS LAST,
                created_timestamp DESC NULLS LAST,
                _id DESC NULLS LAST
        ) AS rnk
    FROM incremental_filter
),
cleaned AS (
    SELECT
        TRIM(store_id::VARCHAR)::INT                    AS store_id,
        TRIM(store_name::VARCHAR)::VARCHAR              AS store_name,
        TRIM(city::VARCHAR)::VARCHAR                    AS city,
        TRIM(province::VARCHAR)::VARCHAR                AS province,
        TRIM(country::VARCHAR)::VARCHAR                 AS country,
        CASE
            WHEN is_active IS NULL THEN NULL
            WHEN UPPER(TRIM(is_active)) = 'Y' THEN TRUE
            ELSE FALSE
        END                                             AS is_active,
        created_timestamp::TIMESTAMP                    AS created_timestamp,
        updated_timestamp::TIMESTAMP                    AS updated_timestamp,
        CURRENT_TIMESTAMP                               AS silver_loaded_at
    FROM deduplicated
    WHERE rnk = 1
)
SELECT * FROM cleaned