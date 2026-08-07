{{ config(
    materialized='incremental',
    unique_key='product_id',
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

WITH incremental_filter AS (
    SELECT
        product_id,
        product_name,
        brand,
        category,
        is_active,
        price,
        created_timestamp,
        updated_timestamp,
        _id
    FROM {{ source('bronze', 'products') }}
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
            PARTITION BY product_id
            ORDER BY
                updated_timestamp DESC NULLS LAST,
                created_timestamp DESC NULLS LAST,
                _id DESC NULLS LAST
        ) AS rnk
    FROM incremental_filter
),

cleaned AS (
    SELECT
        b.brand_id,
        c.category_id,
        d.created_timestamp::TIMESTAMP AS created_timestamp,
        d.updated_timestamp::TIMESTAMP AS updated_timestamp,
        TRIM(d.product_id::VARCHAR)::INT AS product_id,
        TRIM(d.product_name::VARCHAR)::VARCHAR AS product_name,
        CASE
            WHEN d.is_active IS NULL THEN NULL
            WHEN UPPER(TRIM(d.is_active)) = 'Y' THEN TRUE
            ELSE FALSE
        END AS is_active,
        TRIM(d.price::VARCHAR)::NUMERIC AS price,
        CURRENT_TIMESTAMP AS silver_loaded_at
    FROM deduplicated AS d
    LEFT JOIN {{ ref('brands') }} AS b
        ON INITCAP(TRIM(d.brand::VARCHAR)) = b.brand_name
    LEFT JOIN {{ ref('categories') }} AS c
        ON INITCAP(TRIM(d.category::VARCHAR)) = c.category_name
    WHERE d.rnk = 1
)

SELECT * FROM cleaned
