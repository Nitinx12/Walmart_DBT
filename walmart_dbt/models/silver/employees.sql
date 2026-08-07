{{ config(
    materialized='incremental',
    unique_key='employee_id',
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

WITH incremental_filter AS (
    SELECT
        employee_id,
        store_id,
        first_name,
        last_name,
        email,
        job_title,
        is_active,
        salary,
        created_timestamp,
        updated_timestamp,
        _id
    FROM {{ source('bronze', 'employees') }}
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
            PARTITION BY employee_id
            ORDER BY
                updated_timestamp DESC NULLS LAST,
                created_timestamp DESC NULLS LAST,
                _id DESC NULLS LAST
        ) AS rnk
    FROM incremental_filter
),

cleaned AS (
    SELECT
        created_timestamp::TIMESTAMP AS created_timestamp,
        updated_timestamp::TIMESTAMP AS updated_timestamp,
        TRIM(employee_id::VARCHAR)::INT AS employee_id,
        TRIM(store_id::VARCHAR)::INT AS store_id,
        TRIM(CONCAT(first_name, ' ', last_name))::VARCHAR AS employee_name,
        TRIM(email::VARCHAR)::VARCHAR AS email,
        TRIM(job_title::VARCHAR)::VARCHAR AS job_title,
        CASE
            WHEN is_active IS NULL THEN NULL
            WHEN UPPER(TRIM(is_active)) = 'Y' THEN TRUE
            ELSE FALSE
        END AS is_active,
        TRIM(salary::VARCHAR)::NUMERIC AS salary,
        CURRENT_TIMESTAMP AS silver_loaded_at
    FROM deduplicated
    WHERE rnk = 1
)

SELECT * FROM cleaned
