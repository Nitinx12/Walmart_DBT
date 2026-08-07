{{ config(
    materialized='incremental',
    unique_key='order_id',
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

WITH incremental_filter AS (
    SELECT
        order_id,
        store_id,
        customer_id,
        order_status,
        is_active,
        payment_method,
        total_amount,
        order_timestamp,
        created_timestamp,
        updated_timestamp,
        _id
    FROM {{ source('bronze', 'orders') }}

    {% if is_incremental() %}
        WHERE updated_timestamp::TIMESTAMP >= (
            COALESCE(
                (
                    SELECT MAX(t.updated_timestamp::TIMESTAMP)
                    FROM {{ this }} AS t
                ),
                TIMESTAMP '1900-01-01'
            ) - INTERVAL '3 days'
        )
    {% endif %}

),

deduplicated AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY
                updated_timestamp DESC NULLS LAST,
                created_timestamp DESC NULLS LAST,
                _id DESC NULLS LAST
        ) AS rnk
    FROM incremental_filter

),

cleaned AS (
    SELECT
        pm.payment_method_id,
        d.order_timestamp::TIMESTAMP AS order_timestamp,
        d.created_timestamp::TIMESTAMP AS created_timestamp,
        d.updated_timestamp::TIMESTAMP AS updated_timestamp,
        TRIM(d.order_id::VARCHAR)::INT AS order_id,
        TRIM(d.store_id::VARCHAR)::INT AS store_id,
        TRIM(d.customer_id::VARCHAR)::INT AS customer_id,
        TRIM(d.order_status::VARCHAR)::VARCHAR AS order_status,
        CASE
            WHEN d.is_active IS NULL THEN NULL
            WHEN UPPER(TRIM(d.is_active)) = 'Y' THEN TRUE
            ELSE FALSE
        END AS is_active,
        TRIM(d.total_amount::VARCHAR)::NUMERIC AS total_amount,
        CURRENT_TIMESTAMP AS silver_loaded_at
    FROM deduplicated AS d
    LEFT JOIN {{ ref('payment_methods') }} AS pm
        ON UPPER(TRIM(d.payment_method::VARCHAR)) = pm.payment_method_name
    WHERE d.rnk = 1
)

SELECT * FROM cleaned
