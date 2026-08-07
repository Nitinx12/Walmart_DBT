{{ config(
    materialized='incremental',
    incremental_strategy='append'
) }}

WITH source_categories AS (

    SELECT DISTINCT INITCAP(TRIM(category::VARCHAR)) AS category_name
    FROM {{ source('bronze', 'products') }}
    WHERE
        category IS NOT NULL
        AND TRIM(category::VARCHAR) <> ''

),

new_categories AS (

    SELECT sc.category_name
    FROM source_categories AS sc
    {% if is_incremental() %}
        WHERE sc.category_name NOT IN (
            SELECT t.category_name FROM {{ this }} AS t
        )
    {% endif %}

)

SELECT
    {% if is_incremental() %}
        (
            SELECT COALESCE(MAX(t.category_id), 0)
            FROM {{ this }} AS t
        )
        +
    {% endif %}
    ROW_NUMBER() OVER (
        ORDER BY nc.category_name
    ) AS category_id,
    nc.category_name,
    CURRENT_TIMESTAMP AS silver_loaded_at
FROM new_categories AS nc
