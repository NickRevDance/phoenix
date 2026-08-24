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
        , INVENTSTATUSID  -- sign-off fix (Blocker 1): now selected so movement_type can resolve inventory status; was already on silver_byod_inventory_dim, just not pulled through here

    from {{ ref('silver_byod_inventory_dim') }}

),

warehouse as (

    select

          warehouse_key
        , warehouse_id
        , d365_site_id

    from {{ ref('dim_warehouse') }}
    where is_current_row = true  -- sign-off fix (EDW-90 item 4 / latent fan-out finding): no-op today (dim_warehouse is single-version), required before SCD2 snapshot wiring lands -- matches v_current_inventory.sql's pattern

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
        on dt.Date = date(tr.DATEPHYSICAL)

),

transfer_pairs as (

    -- sign-off fix (Blocker 3): resolves each transfer leg's counterparty warehouse.
    -- No linking key exists on the source (MARKINGREFINVENTTRANSORIGIN, TRANSCHILDREFID,
    -- INVENTTRANSORIGINTRANSIT_RU, TRANSCHILDTYPE are all unpopulated in this D365 instance --
    -- confirmed 2026-08-24). Grouping on ReferenceId + ITEMID + size + color + abs(qty) and
    -- keeping only groups with exactly one distinct warehouse per side is a validated proxy:
    -- checked live against all 24,458,898 transfer-category rows, 99.976% resolve to an
    -- unambiguous single warehouse per side (0 ambiguous, 0.024% missing a counterpart leg
    -- entirely). Ambiguous/missing cases correctly fall through to NULL rather than guessing.

    select

          ReferenceId
        , ITEMID
        , INVENTSIZEID
        , INVENTCOLORID
        , abs(QTY) as abs_qty

        , case when count(distinct case when QTY < 0 then warehouse_key end) = 1
            then max(case when QTY < 0 then warehouse_key end)
          end as transfer_out_warehouse_key

        , case when count(distinct case when QTY >= 0 then warehouse_key end) = 1
            then max(case when QTY >= 0 then warehouse_key end)
          end as transfer_in_warehouse_key

    from joined
    where ReferenceCategory in (201, 203)
    group by ReferenceId, ITEMID, INVENTSIZEID, INVENTCOLORID, abs(QTY)

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
            else 'UNKNOWN'  -- sign-off fix (Blocker 2): was "when QTY < 0 then SHIPMENT else RECEIPT" -- silently mislabeled ~111,855 rows (codes 4, 5, 6, 13, 15, 21, 22, 202, NULL) as RECEIPT, 50.2% of that population. Never label by sign alone -- route unmapped codes to UNKNOWN pending deliberate mapping (EDW-7 DQ exception pattern). Characterized live 2026-08-24: codes 5/6/13/15/21/22/202 each split ~50/50 pos/neg with ReferenceId populated ~100%, same shape as 201/203 -- candidates for a second WMS/journal-type bucket, but NEEDS CONFIRMATION before relabeling out of UNKNOWN. Code 4 splits 44/56 with ReferenceId populated only 72% -- looks like a different animal, also NEEDS CONFIRMATION.
          end as movement_type

        , case
            when j.ReferenceCategory = 0 then 'Sales'
            when j.ReferenceCategory = 3 then 'Purchase'
            when j.ReferenceCategory = 26 then 'Adjustment (legacy/placeholder -- all 1900-01-01 dates, see header note)'
            when j.ReferenceCategory = 110 then 'Inventory Journal'
            when j.ReferenceCategory in (201, 203) then 'WMS Work'
            else 'Other (code ' || cast(j.ReferenceCategory as string) || ')'
          end as source_document_type

        , coalesce(nullif(j.INVENTSTATUSID, ''), 'UNKNOWN') as inventory_status_code  -- sign-off fix (Blocker 1): was case when STATUSISSUE != 0 then STATUSISSUE else STATUSRECEIPT end -- those are transaction lifecycle enums, not inventory status, and 100% failed the ref_inventory_status join. UNKNOWN routing is mandatory per review: 2.62M rows (blank INVENTSTATUSID) need it to join ref_inventory_status's own UNKNOWN row.

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
        , case
            when c.movement_type = 'TRANSFER_OUT' then c.warehouse_key
            when c.movement_type = 'TRANSFER_IN' then tp.transfer_out_warehouse_key
          end as from_warehouse_key
        , case
            when c.movement_type = 'TRANSFER_IN' then c.warehouse_key
            when c.movement_type = 'TRANSFER_OUT' then tp.transfer_in_warehouse_key
          end as to_warehouse_key  -- sign-off fix (Blocker 3): scoped to transfers only (was also populating for RECEIPT/RETURN_TO_STOCK, contrary to spec 3.2); counterpart now resolved via transfer_pairs instead of echoing the row's own warehouse_key

    -- Measures
        , c.QTY                                              as quantity_change
        , c.COSTAMOUNTPHYSICAL / nullif(c.QTY, 0)             as unit_cost_at_movement
        , c.COSTAMOUNTPHYSICAL                                as cost_amount_change
        , null qty_uom                           -- Source once available: no UOM column identified on bronze_byod_inventory_trans
        , null quantity_before                   -- Phase 2 per spec
        , null quantity_after                    -- Phase 2 per spec
        , null retail_amount_change              -- Phase 2 per spec

    -- Status
        , c.inventory_status_code
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
    left join transfer_pairs tp
        on c.ReferenceId = tp.ReferenceId
        and c.ITEMID = tp.ITEMID
        and c.INVENTSIZEID = tp.INVENTSIZEID
        and c.INVENTCOLORID = tp.INVENTCOLORID
        and abs(c.QTY) = tp.abs_qty

)

select * from final
