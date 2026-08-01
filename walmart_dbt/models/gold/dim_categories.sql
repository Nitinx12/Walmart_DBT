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

    SELECT category_id, category_name
    FROM source_categories
    {% if is_incremental() %}
    WHERE category_id NOT IN (SELECT category_id FROM {{ this }})
    {% endif %}

)

SELECT
    category_id,
    category_name,
    CURRENT_TIMESTAMP AS gold_loaded_at
FROM new_categories