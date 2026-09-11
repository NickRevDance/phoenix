{{ config(
    materialized = 'incremental',
    unique_key = 'REC',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns'
) }}

SELECT
    *
FROM
    {{ ref('bronze_d365_sales_line') }}

{% if is_incremental() %}
WHERE MODIFIEDDATE > (SELECT coalesce(max(MODIFIEDDATE), timestamp('1900-01-01')) FROM {{ this }}) - interval 2 days
{% endif %}
