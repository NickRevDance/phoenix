{{ config(
    materialized = 'incremental',
    unique_key = 'inventory_movement_key',
    incremental_strategy = 'merge'
) }}

with trans as (

    select

          t.RECID
        , t.INVENTTRANSORIGIN
        , t.INVENTDIMID
        , t.ITEMID
        , t.DATEPHYSICAL
        , t.DATEFINANCIAL
        , t.MODIFIEDDATE
        , t.QTY
        , t.COSTAMOUNTPHYSICAL
        , t.STATUSISSUE
        , t.STATUSRECEIPT
        , t.PACKINGSLIPID
        , t.ReferenceCategory
        , t.ReferenceId

    from {{ ref('silver_byod_inventory_trans') }} t

    {% if is_incremental() %}
    where t.MODIFIEDDATE > (select coalesce(max(etl_source_modified_datetime), timestamp('1900-01-01')) from {{ this }}) - interval 2 days
    {% endif %}

),

origin as (

    select

          RECID
        , INVENTTRANSID

    from {{ ref('silver_byod_inventory_trans_origin') }}

),

inventory_dim as (

    select

          InventDimID
        , inventsiteid
        , INVENTLOCATIONID
        , INVENTSIZEID
        , INVENTCOLORID

    from {{ ref('silver_byod_inventory_dim') }}

),

warehouse as (

    select

          warehouse_key
        , warehouse_id
        , d365_site_id

    from {{ ref('dim_warehouse') }}

),

product as (

    select

          product_key
        , style_number
        , size
        , d365_color_code

    from {{ ref('dim_product') }}
    where version_number = 1

),

joined as (

    select

          tr.*
        , o.INVENTTRANSID
        , wh.warehouse_key
        , pr.product_key
        , dt.DateId as movement_date_key

    from trans tr
    left join origin o
        on tr.INVENTTRANSORIGIN = o.RECID
    left join inventory_dim d
        on tr.INVENTDIMID = d.InventDimID
    left join warehouse wh
        on d.INVENTLOCATIONID = wh.warehouse_id
        and d.inventsiteid = wh.d365_site_id
    left join product pr
        on tr.ITEMID = pr.style_number
        and d.INVENTSIZEID = pr.size
        and d.INVENTCOLORID = pr.d365_color_code
    left join {{ ref('dim_date') }} dt
        on dt.Date = date(tr.DATEPHYSICAL)

),

classified as (

    select

          j.*

        , case
            when j.ReferenceCategory = 0 and j.QTY < 0 then 'SHIPMENT'
            when j.ReferenceCategory = 0 and j.QTY >= 0 then 'RETURN_TO_STOCK'
            when j.ReferenceCategory = 3 then 'RECEIPT'
            when j.ReferenceCategory in (26, 110) then 'ADJUSTMENT'
            when j.ReferenceCategory in (201, 203) and j.QTY < 0 then 'TRANSFER_OUT'
            when j.ReferenceCategory in (201, 203) and j.QTY >= 0 then 'TRANSFER_IN'
            when j.QTY < 0 then 'SHIPMENT'
            else 'RECEIPT'
          end as movement_type

        , case
            when j.ReferenceCategory = 0 then 'Sales'
            when j.ReferenceCategory = 3 then 'Purchase'
            when j.ReferenceCategory = 26 then 'Adjustment (legacy/placeholder -- all 1900-01-01 dates, see header note)'
            when j.ReferenceCategory = 110 then 'Inventory Journal'
            when j.ReferenceCategory in (201, 203) then 'WMS Work'
            else 'Other (code ' || cast(j.ReferenceCategory as string) || ')'
          end as source_document_type

        , case when j.STATUSISSUE != 0 then j.STATUSISSUE else j.STATUSRECEIPT end as inventory_status_code_raw

    from joined j

),

final as (

    select

    -- Core ID
          xxhash64(c.RECID)                     as inventory_movement_key
        , c.DATEPHYSICAL                         as movement_datetime
        , c.movement_date_key
        , c.DATEFINANCIAL                        as posted_datetime
        , c.product_key
        , c.ITEMID                               as product_id
        , c.warehouse_key
        , wh.warehouse_id
        , 'D365'                                 as source_system

    -- Movement
        , c.movement_type
        , null movement_subtype                  -- Source once available: no distinct subtype signal identified beyond ReferenceCategory, which already drives movement_type/movement_reason_code
        , cast(c.ReferenceCategory as string)    as movement_reason_code
        , null movement_reason_desc              -- Source once available: no description lookup for ReferenceCategory identified yet -- Phase 2

    -- Traceability
        , c.source_document_type
        , c.ReferenceId                          as source_document_id
        , null source_document_line_number       -- Source once available: no line-level column identified on InventTrans/InventTransOrigin
        , c.INVENTTRANSID                        as transaction_id
        , c.PACKINGSLIPID                        as receipt_document_id
        , null lot_id                            -- Source once available: silver_byod_inventory_dim.InventBatchId -- Phase 2 per spec

    -- Transfer
        , case when c.movement_type = 'TRANSFER_OUT' then c.warehouse_key end as from_warehouse_key
        , case when c.movement_type in ('TRANSFER_IN', 'RECEIPT', 'RETURN_TO_STOCK') then c.warehouse_key end as to_warehouse_key

    -- Measures
        , c.QTY                                              as quantity_change
        , c.COSTAMOUNTPHYSICAL / nullif(c.QTY, 0)             as unit_cost_at_movement
        , c.COSTAMOUNTPHYSICAL                                as cost_amount_change
        , null qty_uom                           -- Source once available: no UOM column identified on bronze_byod_inventory_trans
        , null quantity_before                   -- Phase 2 per spec
        , null quantity_after                    -- Phase 2 per spec
        , null retail_amount_change              -- Phase 2 per spec

    -- Status
        , cast(c.inventory_status_code_raw as string) as inventory_status_code  -- raw D365 storage-dimension status (STATUSISSUE/STATUSRECEIPT, whichever side is nonzero) -- NOT validated against REF_INVENTORY_STATUS, which doesn't exist yet (see header note)
        , null from_availability_status          -- Phase 2 per spec
        , null to_availability_status            -- Phase 2 per spec
        , null from_lifecycle_status             -- Phase 2 per spec
        , null to_lifecycle_status               -- Phase 2 per spec

    -- Audit
        , 'silver_byod_inventory_trans + silver_byod_inventory_trans_origin + silver_byod_inventory_dim' as record_source_table
        , current_timestamp()                    as etl_insert_datetime
        , current_timestamp()                    as etl_update_datetime
        , c.MODIFIEDDATE                         as etl_source_modified_datetime  -- carried through to drive the incremental filter above (max() against this column on {{ this }})

    from classified c
    left join warehouse wh
        on c.warehouse_key = wh.warehouse_key

)

select * from final