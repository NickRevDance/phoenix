
{{ config(
    materialized = 'incremental',
    unique_key = 'RECID',
    incremental_strategy = 'merge'
) }}
 
    select
        it.*
        , ito.ReferenceCategory
        , ito.ReferenceId
        , ito.recid as invent_trans_origin_id
    from
        {{ref("bronze_byod_inventory_trans")}} it
        left join {{ref("silver_byod_inventory_trans_origin")}} ito
            on it.INVENTTRANSORIGIN = ito.recid
 
    {% if is_incremental() %}
    where it.MODIFIEDDATE > (select coalesce(max(MODIFIEDDATE), timestamp('1900-01-01')) from {{ this }}) - interval 2 days
    {% endif %}
 