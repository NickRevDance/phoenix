{{ config(
    materialized = 'incremental',
    unique_key = 'inventory_movement_key',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns'
) }}

{% set lookback_days = var('inventory_movement_lookback_days', 2) %}
{% set anomaly_qty = var('inventory_movement_anomaly_qty_threshold', 1000000) %}

-- FACT_INVENTORY_MOVEMENT (Inventory Gold Layer spec, Section 3). One row per posted D365
-- inventory transaction leg (InventTrans RECID), the certified record of business movement.
-- It is not a mirror of InventTrans: it reconciles to the source on NET movement, not row for row.
--
-- POPULATION (spec 3.4)
--   In:  physically posted legs (real DATEPHYSICAL) dated 2023-07-01 or later (D365 go-live),
--        in the ReferenceCategory codes mapped below.
--   Out: 201 WHSWork and 203 WHSContainer (bin-level warehouse work), 110 ITMGIT (landed-cost
--        goods-in-transit layer between a warehouse and its -GT location), 26 Blocking and NULL
--        (unposted), every placeholder-date row (1900-01-01), transfer-order legs at a -T
--        transit location, and the non-merchandise service items the snapshot fact also leaves
--        out (fees, catalogs, access requests: var inventory_non_merchandise_items plus CAT-%),
--        so the two inventory facts carry one population.
--
-- MOVEMENT TYPE (spec 3.4, InventTransType enum names)
--   3 Purch                 RECEIPT
--   0 Sales                 SHIPMENT (issue) / RETURN (receipt)
--   21 TransferOrderShip    TRANSFER_OUT       22 TransferOrderReceive   TRANSFER_IN
--   202 WHSQuarantine       STATUS_CHANGE (two legs, paired on voucher)
--   4, 5, 13, 15, 6         ADJUSTMENT, subtype MOVEMENT_JOURNAL / PROFIT_LOSS / COUNT_ADJ /
--                           QUARANTINE_DISPOSAL / TRANSFER_JOURNAL
--   anything else           UNKNOWN (a DQ exception, never a guess)
--   source_document_type stays source-faithful (the enum name); movement_type is the certified
--   taxonomy; movement_reason_code carries the ReferenceCategory code.
--
-- PRODUCT (EDW-93 item 1)
--   Resolved through the D365 item barcode: variant (item + size + colour) to UPC to DIM_PRODUCT,
--   the same path as FACT_INVENTORY_SNAPSHOT_DAILY, so the reconciliation view joins the two
--   facts on one key. The style + size + colour text join is retired. A variant whose UPC is not
--   in DIM_PRODUCT (EDW-134), or that has no barcode row, keeps a NULL product_key and is
--   reported, never dropped.
--
-- PAIRING (EDW-93 item A)
--   Transfer counterparty: the other warehouse on the same transfer order (ReferenceId), read
--   from every leg of that order in silver, posted or not, so a shipped order knows its
--   destination before the receipt posts.
--   Status change counterparty: the other status on the same voucher + ReferenceId + date.
--   On an incremental run the paired categories (21, 22, 202: about 20K legs in all) are always
--   re-read whatever their modified date, so a leg whose partner posts or changes later is
--   corrected on the next run instead of keeping a NULL counterparty.
--
-- INCREMENTAL
--   Merge on inventory_movement_key. Each run re-reads legs modified in the last
--   inventory_movement_lookback_days days (default 2) before the newest modified datetime already
--   loaded; widen the variable for one run to catch up after an outage. A full refresh is safe
--   (silver holds every leg) and is the way to restate history after a rule change.
--
-- KNOWN DATA POINTS
--   Cost: unit_cost_at_movement and cost_amount_change are the posted physical cost. A zero is a
--   posted zero (made-to-order studio apparel and other zero-cost items), not a missing value:
--   every zero-cost row is financially posted (checked 2026-10-01).
--   Quantity anomalies: four D365 keying errors of about 821 billion units (RC23947 on
--   2024-12-26, RD70000 on 2025-06-13), each reversed the same day. They net to one unit, stay in
--   the fact, and carry is_quantity_anomaly_flag = true (any leg at or over
--   inventory_movement_anomaly_qty_threshold units, default 1,000,000). Gross totals by
--   movement type should filter the flag.
--   receipt_document_id is the D365 packing slip id. About 4 percent of vendor receipts have one;
--   the rest post through the landed-cost voyage process, which raises no product receipt.
--   Vendor receipts on a voyage are dated at the voyage's ship date and post into the -GT
--   location first; the arrival at the warehouse is an ITMGIT leg and is not in this fact.

with posted_legs as (

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

    from {{ ref("silver_d365_inventory_trans") }} t

    where date(t.DATEPHYSICAL) >= '2023-07-01'  -- spec 3.4: certified history starts at D365 go-live; also drops the 1900-01-01 placeholder/unposted rows
      and t.ReferenceCategory is not null        -- spec 3.4: unposted/unmapped-at-source rows excluded, not routed to UNKNOWN
      and t.ReferenceCategory not in (26, 110, 201, 203)  -- spec 3.4 excluded populations: Blocking, ITMGIT transit layer, WHSWork/WHSContainer bin-level execution
      -- Non-merchandise service items are not inventory positions (Inventory spec 1.2 / 2.1).
      -- Same maintained list and pattern as fact_inventory_snapshot_daily.
      and t.ITEMID not in ({{ "'" ~ var('inventory_non_merchandise_items') | join("','") ~ "'" }})
      and t.ITEMID not like 'CAT-%'

),

trans as (

    select p.*
    from posted_legs p

    {% if is_incremental() %}
    where p.MODIFIEDDATE > (select coalesce(max(etl_source_modified_datetime), timestamp('1900-01-01')) from {{ this }}) - interval {{ lookback_days }} days

    union all

    -- EDW-93 item A: paired legs (transfer orders, status changes) are always re-read, so a
    -- counterparty that posts or changes outside the window still pairs.
    select p.*
    from posted_legs p
    where p.ReferenceCategory in (21, 22, 202)
      and p.MODIFIEDDATE <= (select coalesce(max(etl_source_modified_datetime), timestamp('1900-01-01')) from {{ this }}) - interval {{ lookback_days }} days
    {% endif %}

),

origin as (

    select

          RECID
        , INVENTTRANSID

    from {{ ref('silver_d365_inventory_trans_origin') }}

),

inventory_dim as (

    select

          InventDimID
        , inventsiteid
        , INVENTLOCATIONID
        , INVENTSIZEID
        , INVENTCOLORID
        , INVENTSTATUSID

    from {{ ref('silver_d365_inventory_dim') }}

),

warehouse as (

    select

          warehouse_key
        , warehouse_id
        , d365_site_id

    from {{ ref('dim_warehouse') }}
    where version_number = 1  -- EDW-90 item 4: fact key resolution resolves against the latest version, not is_current_row

),

product_barcode as (

    -- EDW-93 item 1: variant (item + size + colour) to UPC through the D365 item barcode table,
    -- the same CTE as fact_inventory_snapshot_daily. One barcode per variant (32,069 variants,
    -- none with two, 2026-10-01). The barcode table's own InventDimID is a reference-level
    -- record, so it is read through inventory_dim to size and colour.
    select

          b.ITEMID
        , d.INVENTSIZEID
        , d.INVENTCOLORID
        , min(b.ITEMBARCODE) as upc

    from {{ ref('silver_d365_item_barcode') }} b
    inner join inventory_dim d
        on b.INVENTDIMID = d.InventDimID
    group by 1, 2, 3

),

product as (

    select

          product_key
        , upc

    from {{ ref('dim_product') }}
    where version_number = 1  -- fact key resolution house rule: latest version, not is_current_row

),

joined as (

    select

          tr.*
        , o.INVENTTRANSID
        , wh.warehouse_key
        , wh.warehouse_id
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
    -- EDW-93 item 1: barcode path. Variant -> UPC -> DIM_PRODUCT.
    left join product_barcode pb
        on tr.ITEMID = pb.ITEMID
        and d.INVENTSIZEID = pb.INVENTSIZEID
        and d.INVENTCOLORID = pb.INVENTCOLORID
    left join product pr
        on pb.upc = pr.upc
    left join {{ ref('dim_date') }} dt
        on dt.date = date(tr.DATEPHYSICAL)

    where not (tr.ReferenceCategory in (21, 22) and d.INVENTLOCATIONID like '%-T')  -- spec 3.4: transfer-order transit legs into/out of the -T staging location are in-transit position, not movement

),

transfer_legs as (

    -- EDW-93 item A: every transfer-order leg at a real warehouse, read from the whole silver
    -- table (no incremental window, posted or not). An order that has shipped already has its
    -- receiving leg at the destination as an unposted row, so the destination is known at ship
    -- time. Validated 2026-10-01: 39/39 transfer orders resolve to one warehouse per side.
    select

          t.ReferenceId
        , t.ReferenceCategory
        , wh.warehouse_key

    from {{ ref("silver_d365_inventory_trans") }} t
    left join inventory_dim d
        on t.INVENTDIMID = d.InventDimID
    left join warehouse wh
        on d.INVENTLOCATIONID = wh.warehouse_id
        and d.inventsiteid = wh.d365_site_id

    where t.ReferenceCategory in (21, 22)
      and d.INVENTLOCATIONID not like '%-T'

),

transfer_pairs as (

    -- spec 3.4: counterparty warehouse for real transfer-order legs (21/22) via ReferenceId pairing.

    select

          ReferenceId
        , max(case when ReferenceCategory = 21 then warehouse_key end) as transfer_out_warehouse_key
        , max(case when ReferenceCategory = 22 then warehouse_key end) as transfer_in_warehouse_key

    from transfer_legs
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
    -- paired by VOUCHER + ReferenceId + physical date (pairing must be voucher-keyed, not origin-based,
    -- since each InventTransOrigin only ever touches one status table-wide). Complete on incremental
    -- runs too: every 202 leg is in trans (see the union above).

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
        , c.warehouse_id
        , 'D365'                                 as source_system

    -- Movement
        , c.movement_type
        , c.movement_subtype
        , cast(c.ReferenceCategory as string)    as movement_reason_code
        , cast(null as string) as movement_reason_desc  -- Phase 2 (EDW-50): lookup on REF_MOVEMENT_REASON once it is built

    -- Traceability
        , c.source_document_type
        , nullif(trim(c.ReferenceId), '')        as source_document_id  -- blank on some journals; NULL, never an empty string
        , cast(null as int) as source_document_line_number  -- Source once available: no line-level column identified on InventTrans/InventTransOrigin
        , nullif(trim(c.INVENTTRANSID), '')      as transaction_id
        , nullif(trim(c.PACKINGSLIPID), '')      as receipt_document_id  -- D365 packing slip id; NULL when the leg posted without one (see header)
        , cast(null as string) as lot_id         -- Source once available: silver_d365_inventory_dim.InventBatchId -- Phase 2 per spec

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
        , cast(null as string) as qty_uom        -- Source once available: no UOM column identified on bronze_d365_inventory_trans
        , cast(null as decimal(18,4)) as quantity_before  -- reserved, Phase 3 (Inventory Movement Decision Record v1.0, I1a)
        , cast(null as decimal(18,4)) as quantity_after   -- reserved, Phase 3 (Inventory Movement Decision Record v1.0, I1a)
        , cast(null as decimal(19,4)) as retail_amount_change  -- Phase 2 per spec
        , abs(c.QTY) >= {{ anomaly_qty }}                    as is_quantity_anomaly_flag  -- EDW-93 item C: D365 keying errors stay in the fact, flagged (see header)

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
        , 'silver_d365_inventory_trans + silver_d365_inventory_trans_origin + silver_d365_inventory_dim' as record_source_table
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
    left join transfer_pairs tp
        on c.ReferenceId = tp.ReferenceId
    left join status_change_pairs sc
        on c.VOUCHER = sc.VOUCHER
        and c.ReferenceId = sc.ReferenceId
        and date(c.DATEPHYSICAL) = sc.phys_date

)

select * from final
