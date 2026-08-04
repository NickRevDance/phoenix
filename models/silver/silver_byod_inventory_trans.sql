{{ config(materialized = 'table') }}

    select
        it.*
        , ito.ReferenceCategory
        , ito.ReferenceId
        , ito.recid as invent_trans_origin_id
    from 
        {{ref("bronze_byod_inventory_trans")}} it
        left join {{ref("silver_byod_inventory_trans_origin")}} ito
            on it.INVENTTRANSORIGIN = ito.recid
