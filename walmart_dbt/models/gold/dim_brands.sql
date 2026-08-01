{{ config(
    materialized='incremental',
    incremental_strategy='append'
) }}

WITH source_brands AS (

    SELECT
        brand_id,
        brand_name
    FROM {{ ref('brands') }}

),

new_brands AS (

    SELECT brand_id, brand_name
    FROM source_brands
    {% if is_incremental() %}
    WHERE brand_id NOT IN (SELECT brand_id FROM {{ this }})
    {% endif %}

)

SELECT
    brand_id,
    brand_name,
    CURRENT_TIMESTAMP AS gold_loaded_at
FROM new_brands