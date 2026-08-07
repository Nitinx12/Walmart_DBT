{{ config(
    materialized='incremental',
    incremental_strategy='append'
) }}

WITH source_brands AS (

    SELECT DISTINCT INITCAP(TRIM(brand::VARCHAR)) AS brand_name
    FROM {{ source('bronze', 'products') }}
    WHERE
        brand IS NOT NULL
        AND TRIM(brand::VARCHAR) <> ''

),

new_brands AS (

    SELECT sb.brand_name
    FROM source_brands AS sb
    {% if is_incremental() %}
        WHERE sb.brand_name NOT IN (
            SELECT t.brand_name FROM {{ this }} AS t
        )
    {% endif %}

)

SELECT
    {% if is_incremental() %}
        (
            SELECT COALESCE(MAX(t.brand_id), 0)
            FROM {{ this }} AS t
        )
        +
    {% endif %}
    ROW_NUMBER() OVER (
        ORDER BY nb.brand_name
    ) AS brand_id,
    nb.brand_name,
    CURRENT_TIMESTAMP AS silver_loaded_at
FROM new_brands AS nb
