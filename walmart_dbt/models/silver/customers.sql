{{ config(
    materialized='incremental',
    unique_key='customer_id',
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

WITH incremental_filter AS (
    SELECT
        customer_id,
        first_name,
        last_name,
        phone,
        email,
        is_active,
        city,
        province,
        country,
        created_timestamp,
        updated_timestamp,
        _id
    FROM {{ source('bronze', 'customers') }}
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
            PARTITION BY customer_id
            ORDER BY
                updated_timestamp DESC NULLS LAST,
                created_timestamp DESC NULLS LAST,
                _id DESC NULLS LAST
        ) AS rnk
    FROM incremental_filter
),

phone_split AS (
    -- separate the extension (anything after 'x') from the main number
    SELECT
        *,
        SPLIT_PART(LOWER(TRIM(phone::VARCHAR)), 'x', 1) AS phone_main_part,
        NULLIF(SPLIT_PART(LOWER(TRIM(phone::VARCHAR)), 'x', 2), '')
            AS phone_ext_part
    FROM deduplicated
    WHERE rnk = 1
),

phone_digits AS (
    -- strip everything down to raw digits on each part
    SELECT
        *,
        REGEXP_REPLACE(phone_main_part, '[^0-9]', '', 'g') AS phone_digits,
        REGEXP_REPLACE(COALESCE(phone_ext_part, ''), '[^0-9]', '', 'g')
            AS phone_ext_digits
    FROM phone_split
),

cleaned AS (
    SELECT
        created_timestamp::TIMESTAMP AS created_timestamp,
        updated_timestamp::TIMESTAMP AS updated_timestamp,
        TRIM(customer_id::VARCHAR)::INT AS customer_id,
        TRIM(CONCAT(first_name, ' ', last_name))::VARCHAR AS customer_name,
        CASE
            -- a valid NANP number always has exactly 10 significant digits;
            -- whatever junk precedes them (+1-, 001-, nothing) is discarded
            -- by always taking the rightmost 10 digits.
            -- fewer than 10 digits = not a valid number, flagged as NULL
            -- rather than stored as garbage
            WHEN LENGTH(phone_digits) >= 10
                THEN
                    '+1-' || SUBSTRING(RIGHT(phone_digits, 10), 1, 3) || '-'
                    || SUBSTRING(RIGHT(phone_digits, 10), 4, 3) || '-'
                    || SUBSTRING(RIGHT(phone_digits, 10), 7, 4)
        END AS phone,
        NULLIF(phone_ext_digits, '') AS phone_extension,
        TRIM(email::VARCHAR)::VARCHAR AS email,
        CASE
            WHEN is_active IS NULL THEN NULL
            WHEN UPPER(TRIM(is_active)) = 'Y' THEN TRUE
            ELSE FALSE
        END AS is_active,
        TRIM(city::VARCHAR)::VARCHAR AS city,
        TRIM(province::VARCHAR)::VARCHAR AS province,
        TRIM(country::VARCHAR)::VARCHAR AS country,
        CURRENT_TIMESTAMP AS silver_loaded_at
    FROM phone_digits
)

SELECT
    created_timestamp,
    updated_timestamp,
    customer_id,
    customer_name,
    phone,
    phone_extension,
    email,
    is_active,
    city,
    province,
    country,
    silver_loaded_at
FROM cleaned
