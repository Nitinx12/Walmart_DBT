{{ config(
    materialized='incremental',
    incremental_strategy='append'
) }}

WITH source_methods AS (

    SELECT DISTINCT UPPER(TRIM(payment_method::VARCHAR)) AS payment_method_name
    FROM {{ source('bronze', 'orders') }}
    WHERE
        payment_method IS NOT NULL
        AND TRIM(payment_method::VARCHAR) <> ''

),

new_methods AS (

    SELECT payment_method_name
    FROM source_methods
    {% if is_incremental() %}
        WHERE
            payment_method_name NOT IN (
                SELECT payment_method_name FROM {{ this }}
            )
    {% endif %}

)

SELECT
    {% if is_incremental() %}
        (SELECT COALESCE(MAX(payment_method_id), 0) FROM {{ this }}) +
    {% endif %}
    ROW_NUMBER() OVER (ORDER BY payment_method_name) AS payment_method_id,
    payment_method_name,
    CURRENT_TIMESTAMP AS silver_loaded_at
FROM new_methods
