
{{ config(
    materialized = 'incremental',
    unique_key = 'RECID',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    liquid_clustered_by = ['MODIFIEDDATE', 'RECID'],
    merge_exclude_columns = ['is_deleted', 'deleted_detected_datetime'],
    post_hook = ["{{ flag_source_deletes('RECID', ref('bronze_d365_inventory_trans_keys')) }}"]
) }}

-- EDW-177: legs deleted in D365 (including the original RECID when D365 splits a leg) are kept and
-- marked is_deleted by the post-hook, checked against the current extract's keys.
-- depends_on: {{ ref('bronze_d365_inventory_trans_keys') }}

    select
        it.*
        , ito.ReferenceCategory
        , ito.ReferenceId
        , ito.recid as invent_trans_origin_id
        , cast(0 as int)          as is_deleted
        , cast(null as timestamp) as deleted_detected_datetime
    from
        {{ref("bronze_d365_inventory_trans")}} it
        left join {{ref("silver_d365_inventory_trans_origin")}} ito
            on it.INVENTTRANSORIGIN = ito.recid

    {% if is_incremental() %}
    where it.MODIFIEDDATE > (select coalesce(max(MODIFIEDDATE), timestamp('1900-01-01')) from {{ this }}) - interval 2 days
    {% endif %}
