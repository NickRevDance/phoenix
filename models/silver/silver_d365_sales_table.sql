{{ config(
    materialized = 'incremental',
    unique_key = 'REC',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    merge_exclude_columns = ['is_deleted', 'deleted_detected_datetime'],
    full_refresh = false,
    post_hook = ["{{ flag_source_deletes('REC', ref('bronze_d365_sales_table')) }}"]
) }}

-- EDW-177: merges the full header extract each run (about 710K rows) instead of rebuilding, so an
-- order deleted in D365 keeps its header, marked is_deleted by the post-hook. No watermark: every
-- header is re-read, the same coverage the table rebuild had. An empty extract merges nothing.
-- full_refresh = false: a rebuild from the extract would lose every retained delete.

SELECT
    *
    , cast(0 as int)          AS is_deleted
    , cast(null as timestamp) AS deleted_detected_datetime
FROM
    {{ ref('bronze_d365_sales_table') }}
