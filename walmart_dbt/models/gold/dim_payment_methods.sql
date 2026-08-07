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

    SELECT
        sm.payment_method_id,
        sm.payment_method_name
    FROM source_methods AS sm
    {% if is_incremental() %}
        WHERE sm.payment_method_id NOT IN (
            SELECT t.payment_method_id
            FROM {{ this }} AS t
        )
    {% endif %}

)

SELECT
    payment_method_id,
    payment_method_name,
    CURRENT_TIMESTAMP AS gold_loaded_at
FROM new_methods