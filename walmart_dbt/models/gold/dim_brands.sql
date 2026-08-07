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

    SELECT
        sb.brand_id,
        sb.brand_name
    FROM source_brands AS sb
    {% if is_incremental() %}
        WHERE sb.brand_id NOT IN (
            SELECT t.brand_id
            FROM {{ this }} AS t
        )
    {% endif %}

)

SELECT
    brand_id,
    brand_name,
    CURRENT_TIMESTAMP AS gold_loaded_at
FROM new_brands