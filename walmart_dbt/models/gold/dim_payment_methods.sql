{{ config(
    materialized='incremental',
    incremental_strategy='append'
) }}

WITH source_methods AS (

    SELECT
        payment_method_id,
        payment_method_name
    FROM {{ ref('payment_methods') }}

),

new_methods AS (

    SELECT payment_method_id, payment_method_name
    FROM source_methods
    {% if is_incremental() %}
    WHERE payment_method_id NOT IN (SELECT payment_method_id FROM {{ this }})
    {% endif %}

)

SELECT
    payment_method_id,
    payment_method_name,
    CURRENT_TIMESTAMP AS gold_loaded_at
FROM new_methods