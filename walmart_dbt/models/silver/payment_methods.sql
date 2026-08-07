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

    SELECT sm.payment_method_name
    FROM source_methods AS sm
    {% if is_incremental() %}
        WHERE
            sm.payment_method_name NOT IN (
                SELECT t.payment_method_name FROM {{ this }} AS t
            )
    {% endif %}

)

SELECT
    {% if is_incremental() %}
        (
            SELECT COALESCE(MAX(t.payment_method_id), 0)
            FROM {{ this }} AS t
        )
        +
    {% endif %}
    ROW_NUMBER() OVER (
        ORDER BY nm.payment_method_name
    ) AS payment_method_id,
    nm.payment_method_name,
    CURRENT_TIMESTAMP AS silver_loaded_at
FROM new_methods AS nm
