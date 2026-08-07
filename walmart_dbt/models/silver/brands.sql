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

    SELECT brand_name
    FROM source_brands
    {% if is_incremental() %}
        WHERE brand_name NOT IN (SELECT brand_name FROM {{ this }})
    {% endif %}

)

SELECT
    {% if is_incremental() %}
        (SELECT COALESCE(MAX(brand_id), 0) FROM {{ this }}) +
    {% endif %}
    ROW_NUMBER() OVER (ORDER BY brand_name) AS brand_id,
    brand_name,
    CURRENT_TIMESTAMP AS silver_loaded_at
FROM new_brands
