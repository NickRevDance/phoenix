{{ config(
    materialized = 'incremental',
    unique_key = 'REC',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    merge_exclude_columns = ['is_deleted', 'deleted_detected_datetime'],
    full_refresh = false,
    post_hook = ["{{ flag_source_deletes('REC', ref('bronze_d365_sales_line')) }}"]
) }}

-- EDW-177: lines deleted in D365 are kept and marked (is_deleted, set by the post-hook), never dropped.
-- full_refresh = false: a rebuild from the extract would lose every retained delete.

SELECT
    *
    , cast(0 as int)          AS is_deleted
    , cast(null as timestamp) AS deleted_detected_datetime
FROM
    {{ ref('bronze_d365_sales_line') }}

{% if is_incremental() %}
WHERE MODIFIEDDATE > (SELECT coalesce(max(MODIFIEDDATE), timestamp('1900-01-01')) FROM {{ this }}) - interval 2 days
{% endif %}
