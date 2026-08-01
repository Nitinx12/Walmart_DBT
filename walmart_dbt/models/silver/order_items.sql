{{ config(
    materialized='incremental',
    unique_key='order_item_id',
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

WITH incremental_filter AS (
    SELECT
        order_item_id,
        order_id,
        product_id,
        is_active,
        quantity,
        unit_price,
        line_amount,
        created_timestamp,
        updated_timestamp,
        _id
    FROM {{ source('bronze', 'order_items') }}

    {% if is_incremental() %}
    WHERE updated_timestamp::TIMESTAMP >= (
        COALESCE(
            (SELECT MAX(updated_timestamp::TIMESTAMP) FROM {{ this }}),
            TIMESTAMP '1900-01-01'
        ) - INTERVAL '3 days'
    )
    {% endif %}
),
deduplicated AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY order_item_id
            ORDER BY
                updated_timestamp DESC NULLS LAST,
                created_timestamp DESC NULLS LAST,
                _id DESC NULLS LAST
        ) AS rnk
    FROM incremental_filter
),
cleaned AS (
    SELECT
        TRIM(order_item_id::VARCHAR)::INT           AS order_item_id,
        TRIM(order_id::VARCHAR)::INT                AS order_id,
        TRIM(product_id::VARCHAR)::INT               AS product_id,
        CASE
            WHEN is_active IS NULL THEN NULL
            WHEN UPPER(TRIM(is_active)) = 'Y' THEN TRUE
            ELSE FALSE
        END                                         AS is_active,
        TRIM(quantity::VARCHAR)::INT                AS quantity,
        TRIM(unit_price::VARCHAR)::NUMERIC          AS unit_price,
        TRIM(line_amount::VARCHAR)::NUMERIC         AS line_amount,
        created_timestamp::TIMESTAMP                AS created_timestamp,
        updated_timestamp::TIMESTAMP                AS updated_timestamp,
        CURRENT_TIMESTAMP                           AS silver_loaded_at
    FROM deduplicated
    WHERE rnk = 1

)
SELECT * FROM cleaned