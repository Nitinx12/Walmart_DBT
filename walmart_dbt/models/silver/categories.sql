{{ config(
    materialized='incremental',
    incremental_strategy='append'
) }}

WITH source_categories AS (

    SELECT DISTINCT
        INITCAP(TRIM(category::VARCHAR)) AS category_name
    FROM {{ source('bronze', 'products') }}
    WHERE category IS NOT NULL
      AND TRIM(category::VARCHAR) <> ''

),

new_categories AS (

    SELECT category_name
    FROM source_categories
    {% if is_incremental() %}
    WHERE category_name NOT IN (SELECT category_name FROM {{ this }})
    {% endif %}

)

SELECT
    {% if is_incremental() %}
    (SELECT COALESCE(MAX(category_id), 0) FROM {{ this }}) +
    {% endif %}
    ROW_NUMBER() OVER (ORDER BY category_name)      AS category_id,
    category_name,
    CURRENT_TIMESTAMP                               AS silver_loaded_at
FROM new_categories