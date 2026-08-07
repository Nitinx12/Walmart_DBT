{{ config(
    materialized='incremental',
    incremental_strategy='append'
) }}

WITH source_categories AS (

    SELECT
        category_id,
        category_name
    FROM {{ ref('categories') }}

),

new_categories AS (

    SELECT
        sc.category_id,
        sc.category_name
    FROM source_categories AS sc
    {% if is_incremental() %}
        WHERE sc.category_id NOT IN (
            SELECT t.category_id
            FROM {{ this }} AS t
        )
    {% endif %}

)

SELECT
    category_id,
    category_name,
    CURRENT_TIMESTAMP AS gold_loaded_at
FROM new_categories
