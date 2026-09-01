{{ config(
    materialized = 'incremental',
    unique_key = 'inventory_movement_key',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns'
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
        , t.PACKINGSLIPID
        , t.ReferenceCategory
        , t.ReferenceId
        , t.VOUCHER

    from {{ ref('silver_byod_inventory_trans') }} t

    where date(t.DATEPHYSICAL) >= '2023-07-01'  -- spec 3.4: certified history starts at D365 go-live; also drops the 1900-01-01 placeholder/unposted rows
      and t.ReferenceCategory is not null        -- spec 3.4: unposted/unmapped-at-source rows excluded, not routed to UNKNOWN
      and t.ReferenceCategory not in (26, 110, 201, 203)  -- spec 3.4 excluded populations: Blocking, ITMGIT transit layer, WHSWork/WHSContainer bin-level execution

    {% if is_incremental() %}
    and t.MODIFIEDDATE > (select coalesce(max(etl_source_modified_datetime), timestamp('1900-01-01')) from {{ this }}) - interval 2 days
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
        , INVENTSTATUSID

    from {{ ref('silver_byod_inventory_dim') }}

),

warehouse as (

    select

          warehouse_key
        , warehouse_id
        , d365_site_id

    from {{ ref('dim_warehouse') }}
    where is_current_row = true

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
        , dt.date_key as movement_date_key
        , d.INVENTLOCATIONID
        , d.INVENTSIZEID
        , d.INVENTCOLORID
        , d.INVENTSTATUSID

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
        on dt.date = date(tr.DATEPHYSICAL)

    where not (tr.ReferenceCategory in (21, 22) and d.INVENTLOCATIONID like '%-T')  -- spec 3.4: transfer-order transit legs into/out of the -T staging location are in-transit position, not movement

),

transfer_pairs as (

    -- spec 3.4: counterparty warehouse for real transfer-order legs (21/22) via ReferenceId pairing.
    -- Validated live 2026-08-27: 39/39 transfer orders resolve to exactly one warehouse per side, quantities tie to zero.

    select

          ReferenceId
        , max(case when ReferenceCategory = 21 then warehouse_key end) as transfer_out_warehouse_key
        , max(case when ReferenceCategory = 22 then warehouse_key end) as transfer_in_warehouse_key

    from joined
    where ReferenceCategory in (21, 22)
    group by ReferenceId

),

classified as (

    select

          j.*

        , case
            when j.ReferenceCategory = 3 then 'RECEIPT'
            when j.ReferenceCategory = 0 and j.QTY < 0 then 'SHIPMENT'
            when j.ReferenceCategory = 0 and j.QTY >= 0 then 'RETURN'
            when j.ReferenceCategory = 21 then 'TRANSFER_OUT'
            when j.ReferenceCategory = 22 then 'TRANSFER_IN'
            when j.ReferenceCategory = 202 then 'STATUS_CHANGE'
            when j.ReferenceCategory in (4, 5, 6, 13, 15) then 'ADJUSTMENT'
            else 'UNKNOWN'  -- spec 3.4: no catch-all to a real type; any code outside the mapped set is a DQ exception, not a guess
          end as movement_type

        , case
            when j.ReferenceCategory = 4 then 'MOVEMENT_JOURNAL'
            when j.ReferenceCategory = 5 then 'PROFIT_LOSS'
            when j.ReferenceCategory = 13 then 'COUNT_ADJ'
            when j.ReferenceCategory = 15 then 'QUARANTINE_DISPOSAL'
            when j.ReferenceCategory = 6 then 'TRANSFER_JOURNAL'
          end as movement_subtype

        , case
            when j.ReferenceCategory = 3 then 'Purch'
            when j.ReferenceCategory = 0 then 'Sales'
            when j.ReferenceCategory = 21 then 'TransferOrderShip'
            when j.ReferenceCategory = 22 then 'TransferOrderReceive'
            when j.ReferenceCategory = 202 then 'WHSQuarantine'
            when j.ReferenceCategory = 4 then 'InventTransaction'
            when j.ReferenceCategory = 5 then 'InventLossProfit'
            when j.ReferenceCategory = 13 then 'InventCounting'
            when j.ReferenceCategory = 15 then 'QuarantineOrder'
            when j.ReferenceCategory = 6 then 'InventTransfer'
            else 'Other (code ' || cast(j.ReferenceCategory as string) || ')'
          end as source_document_type

        , coalesce(nullif(j.INVENTSTATUSID, ''), 'UNKNOWN') as inventory_status_code  -- must be INVENTSTATUSID, not STATUSISSUE/STATUSRECEIPT (those are transaction lifecycle states, not inventory status)

    from joined j

),

status_change_pairs as (

    -- spec 3.1/3.3: a D365 status change posts as two legs (issue from old status, receipt into new status)
    -- paired by VOUCHER + ReferenceId + physical date (per Blocker 2 note: pairing must be voucher-keyed,
    -- not origin-based, since each InventTransOrigin only ever touches one status table-wide).

    select

          VOUCHER
        , ReferenceId
        , date(DATEPHYSICAL) as phys_date
        , max(case when QTY < 0 then inventory_status_code end) as from_status_code
        , max(case when QTY >= 0 then inventory_status_code end) as to_status_code

    from classified
    where ReferenceCategory = 202
    group by VOUCHER, ReferenceId, date(DATEPHYSICAL)

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
        , c.movement_subtype
        , cast(c.ReferenceCategory as string)    as movement_reason_code
        , cast(null as string) as movement_reason_desc  -- Source once available: no description lookup for ReferenceCategory identified yet -- Phase 2

    -- Traceability
        , c.source_document_type
        , c.ReferenceId                          as source_document_id
        , cast(null as int) as source_document_line_number  -- Source once available: no line-level column identified on InventTrans/InventTransOrigin
        , c.INVENTTRANSID                        as transaction_id
        , c.PACKINGSLIPID                        as receipt_document_id
        , cast(null as string) as lot_id         -- Source once available: silver_byod_inventory_dim.InventBatchId -- Phase 2 per spec

    -- Transfer
        , case
            when c.movement_type = 'TRANSFER_OUT' then c.warehouse_key
            when c.movement_type = 'TRANSFER_IN' then tp.transfer_out_warehouse_key
          end as from_warehouse_key
        , case
            when c.movement_type = 'TRANSFER_IN' then c.warehouse_key
            when c.movement_type = 'TRANSFER_OUT' then tp.transfer_in_warehouse_key
          end as to_warehouse_key

    -- Measures
        , c.QTY                                              as quantity_change
        , c.COSTAMOUNTPHYSICAL / nullif(c.QTY, 0)             as unit_cost_at_movement
        , c.COSTAMOUNTPHYSICAL                                as cost_amount_change
        , cast(null as string) as qty_uom        -- Source once available: no UOM column identified on bronze_byod_inventory_trans
        , cast(null as decimal(18,4)) as quantity_before  -- Phase 2 per spec
        , cast(null as decimal(18,4)) as quantity_after   -- Phase 2 per spec
        , cast(null as decimal(19,4)) as retail_amount_change  -- Phase 2 per spec

    -- Status
        , c.inventory_status_code
        , case
            when c.movement_type = 'STATUS_CHANGE' and c.QTY < 0 then sc.to_status_code
            when c.movement_type = 'STATUS_CHANGE' and c.QTY >= 0 then sc.from_status_code
          end as counterparty_inventory_status_code
        , cast(null as string) as from_availability_status  -- Phase 2 per spec
        , cast(null as string) as to_availability_status    -- Phase 2 per spec
        , cast(null as string) as from_lifecycle_status     -- Phase 2 per spec
        , cast(null as string) as to_lifecycle_status       -- Phase 2 per spec

    -- Audit
        , 'silver_byod_inventory_trans + silver_byod_inventory_trans_origin + silver_byod_inventory_dim' as record_source_table
        , current_timestamp()                    as etl_insert_datetime
        , current_timestamp()                    as etl_update_datetime
        , c.MODIFIEDDATE                         as etl_source_modified_datetime  -- drives the incremental filter above (max() against this column on {{ this }})
        , sha2(
            concat_ws('||'
              , coalesce(cast(c.QTY as string), '')
              , coalesce(cast(c.COSTAMOUNTPHYSICAL as string), '')
              , coalesce(c.inventory_status_code, '')
              , coalesce(cast(c.warehouse_key as string), '')
              , coalesce(cast(c.product_key as string), '')
            ), 256
          )                                      as row_hash

    from classified c
    left join warehouse wh
        on c.warehouse_key = wh.warehouse_key
    left join transfer_pairs tp
        on c.ReferenceId = tp.ReferenceId
    left join status_change_pairs sc
        on c.VOUCHER = sc.VOUCHER
        and c.ReferenceId = sc.ReferenceId
        and date(c.DATEPHYSICAL) = sc.phys_date

)

select * from final
