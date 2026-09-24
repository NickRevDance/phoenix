{{ config(
    materialized = 'incremental',
    unique_key = 'inventory_snapshot_key',
    incremental_strategy = 'merge'
) }}

-- FACT_INVENTORY_SNAPSHOT_DAILY (Inventory Gold Layer spec v2.6, Section 2).
-- Incremental/merge so this fact accumulates real daily history (spec grain
-- includes snapshot_date_key). Ongoing rows are always native InventSum/InventDim,
-- stamped current_date(). History before the native pipeline existed is backfilled
-- from the legacy analytics.f_KPI_InventoryValue report via the is_incremental()
-- branch below, which only runs on the first build or a --full-refresh.
--
-- *** NEVER --full-refresh THIS MODEL IN PROD (EDW-117, spec 2.7). ***
-- The native branch can only produce today; a full refresh rebuilds backfill + today
-- and destroys every accumulated native day (that is how Aug 21-31 2026 was lost).
-- Corrections to history are applied in place (MERGE / INSERT / DELETE with a
-- backup clone first), never by rebuilding. The two branches are different
-- populations (spec 2.5): backfill rows are the legacy KPI population (weekly cadence
-- before 2026, daily since; all statuses only from mid-2026), native rows are all
-- statuses, all warehouses, daily. Every row states its branch in record_source_table,
-- a constant per branch from the inventory_snapshot_branch_label() macro (item 5).
--
-- EDW-117 remediation applied in this revision (Sep 2026):
--   item 1  product resolution via the D365 barcode path (variant -> UPC -> DIM_PRODUCT),
--           the grain DIM_PRODUCT is keyed on; the style + size + colour text join is gone.
--           Non-merchandise service items (fees, catalogs, access requests) filtered.
--   item 2  backfill seam moved to the inventory_snapshot_native_start_date() macro.
--   item 3  zero-position filter: a native row is kept only if any quantity measure
--           (on hand, reserved, available, on order, in transit) is non-zero.
--   item 4  inventsiteid added to the key. dim_warehouse read at version_number = 1 (EDW-90 item 4).
--   item 5  record_source_table via macro.
--   dim_product read at is_current_row = 1 (was version_number = 1, which serves an
--           invalidated row as current under hard_deletes: invalidate).

with on_hand_raw as (

    select

          ItemID
        , INVENTSIZEID
        , INVENTCOLORID
        , INVENTLOCATIONID
        , inventsiteid
        , InventDimID
        , PHYSICALINVENT
        , RESERVPHYSICAL
        , AVAILPHYSICAL

    from {{ ref('silver_d365_inventory_sum') }}

),

inventory_dim as (

    select

          InventDimID
        , coalesce(nullif(INVENTSTATUSID, ''), 'UNKNOWN') as inventory_status_code  -- sign-off fix (spec 2.3 rule): was nullif-only, leaving blank statuses as NULL in the grain column instead of routing them to the UNKNOWN member per the EDW-7 unknown-mapping pattern
        , INVENTSIZEID
        , INVENTCOLORID
        , INVENTLOCATIONID
        , inventsiteid

    from {{ ref('silver_d365_inventory_dim') }}

),

on_hand_with_status as (

    select

          r.ItemID
        , r.INVENTSIZEID
        , r.INVENTCOLORID
        , r.INVENTLOCATIONID
        , r.inventsiteid
        , d.inventory_status_code
        , r.PHYSICALINVENT
        , r.RESERVPHYSICAL
        , r.AVAILPHYSICAL

    from on_hand_raw r
    left join inventory_dim d
        on r.InventDimID = d.InventDimID

),

on_hand_agg as (

    select

          ItemID
        , INVENTSIZEID
        , INVENTCOLORID
        , INVENTLOCATIONID
        , inventsiteid
        , inventory_status_code
        , sum(PHYSICALINVENT)  as on_hand_qty
        , sum(RESERVPHYSICAL)  as reserved_qty
        , sum(AVAILPHYSICAL)   as available_qty
        , current_date()       as snapshot_date

    from on_hand_with_status
    -- EDW-117 item 11: non-merchandise service items are not inventory positions.
    -- D365 carries fee, catalog and request items with a stock quantity (Artwork Fee,
    -- Customization Fee, CAT-*-27 catalogs, ACCESSREQ). They never resolve to DIM_PRODUCT
    -- and must not be NULL-key rows. Maintained list in dbt_project.yml vars.
    where ItemID not in ({{ "'" ~ var('inventory_non_merchandise_items') | join("','") ~ "'" }})
      and ItemID not like 'CAT-%'
    group by 1, 2, 3, 4, 5, 6

),

product_barcode as (

    -- EDW-117 item 1: the D365 variant (item + size + colour) resolves to its UPC through
    -- the item barcode table (EA / Code 39 rows in silver), and the UPC is DIM_PRODUCT's
    -- key (product_key = md5(UPC)). Verified on prod 2026-09-22: one barcode per variant,
    -- one current DIM_PRODUCT row per UPC, zero cases the old text join resolved that this
    -- path does not. Residual misses are UPCs absent from DIM_PRODUCT (EDW-134) and a
    -- handful of hand-keyed variants with no barcode row; both reported, never dropped.
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
        , sku
        , style_number
        , erp_status
        , plm_status
        , Vintage
        , debut_date

    from {{ ref('dim_product') }}
    where is_current_row = 1  -- EDW-117: not version_number = 1, which keeps serving a row invalidated by hard_deletes

),

warehouse as (

    select

          warehouse_key
        , warehouse_id
        , d365_site_id

    from {{ ref('dim_warehouse') }}
    where version_number = 1  -- EDW-90 item 4: fact key resolution resolves against the latest version, not is_current_row

),

inventory_status as (

    select

          inventory_status_code
        , availability_class

    from {{ ref('ref_inventory_status') }}
    where is_current_row = 1

),

product_cost as (

    select

          product_id
        , standard_cost_unit
        , cost_currency_code

    from {{ ref('fact_product_cost') }}
    where is_current = true
      and cost_type = 'STANDARD'  -- bug fix 2026-09-03: fact_product_cost is grained by cost_type x effective_date (insert-only accumulating history, rebuilt 2026-09-01) -- an unfiltered join here fans every inventory row out to one source row per cost_type/effective_date version, which broke the incremental MERGE (DELTA_MULTIPLE_SOURCE_ROW_MATCHING_TARGET_ROW_IN_MERGE) once fact_product_cost accumulated more than one row per product_key

),

product_cost_landed as (

    -- 2026-09-16 hardening: dedup guard added after fact_product_cost's is_current briefly
    -- violated its 1-row-per-product-key contract (LANDED entity-key drift bug, fixed same
    -- day in gold/fact_product_cost.sql) and fanned this fact out to 3 duplicate keys. This
    -- guard is defense-in-depth -- keeps a future is_current violation from doing it again --
    -- same rank/dedup pattern as the item_warehouse_supply_rank guard below.
    select

          product_id
        , landed_cost_unit

    from (
        select

              product_id
            , landed_cost_unit
            , row_number() over (
                partition by product_id
                order by effective_date desc, etl_insert_datetime desc
              ) as landed_cost_rank

        from {{ ref('fact_product_cost') }}
        where is_current = true
          and cost_type = 'LANDED'
    )
    where landed_cost_rank = 1

),

open_po_agg as (

    -- EDW-46: on_order_qty source, sourced 2026-09-10 from native PurchLine (Rev_PurchLineStaging via
    -- silver_d365_purch_line, filtered PURCHSTATUS = 1 / Backorder). Confirmed live: REMAINPURCHPHYSICAL
    -- equals PURCHQTY exactly for every open line (nothing received yet), 0 for Received/Invoiced/Canceled --
    -- this is a clean open-PO-totals measure, reconciles to D365 by construction.
    select

          p.ITEMID
        , d.INVENTSIZEID
        , d.INVENTCOLORID
        , d.INVENTLOCATIONID
        , d.inventsiteid
        , sum(p.REMAINPURCHPHYSICAL) as on_order_qty

    from {{ ref('silver_d365_purch_line') }} p
    left join inventory_dim d
        on p.INVENTDIMID = d.InventDimID
    group by 1, 2, 3, 4, 5

),

goods_in_transit_agg as (

    -- EDW-46: in_transit_inbound_qty source, sourced 2026-09-10 from Rev_ItmGoodsInTransitOrderStaging
    -- via silver_d365_itm_goods_in_transit_order (STATUS = 1, not yet received). Confirmed live: 100% of
    -- these rows (952/952) join to a real PurchTable.PURCHID via TRANSREFID -- this table is vendor-PO
    -- goods-in-transit only, not inter-warehouse (0 matches against InventTransferTable).
    select

          g.ITEMID
        , d.INVENTSIZEID
        , d.INVENTCOLORID
        , d.INVENTLOCATIONID
        , d.inventsiteid
        , sum(g.REMAINQTY) as in_transit_inbound_qty

    from {{ ref('silver_d365_itm_goods_in_transit_order') }} g
    left join inventory_dim d
        on g.INVENTDIMID = d.InventDimID
    group by 1, 2, 3, 4, 5

),

transfer_in_transit_agg as (

    -- EDW-46: in_transit_transfer_qty source, sourced 2026-09-10 from Rev_InventTransferLineStaging via
    -- silver_d365_invent_transfer_line, keyed to the DESTINATION warehouse leg (INVENTDIMIDTO_RU).
    -- Table carries 0 rows in the warehouse today (no live transfer-order activity) -- wired for when
    -- transfer activity starts rather than left unbuilt, since the source and join logic are both real.
    select

          t.ITEMID
        , d.INVENTSIZEID
        , d.INVENTCOLORID
        , d.INVENTLOCATIONID
        , d.inventsiteid
        , sum(t.QTYSHIPPED - t.QTYRECEIVED) as in_transit_transfer_qty

    from {{ ref('silver_d365_inventory_transfer_line') }} t
    left join inventory_dim d
        on t.INVENTDIMIDTO_RU = d.InventDimID
    group by 1, 2, 3, 4, 5

),

snapshot_date_dim as (

    select

          date_key
        , Date

    from {{ ref('dim_date') }}

),

product_price as (

    -- EDW-49: current USD list price, one row per product_key (variant)
    select

          product_key
        , list_price_usd

    from {{ ref('v_product_price_current') }}

),

last_sale_agg as (

    -- EDW-49: current-state MAX, not point-in-time, so native branch only
    select

          product_key
        , warehouse_key
        , cast(max(invoice_date) as date) as last_sale_date

    from {{ ref('fact_sales_invoice') }}
    where not coalesce(is_return_flag, false)
    group by 1, 2

),

joined as (

    select

          oh.*
        , pr.product_key
        , coalesce(pr.upc, pb.upc)              as upc  -- EDW-117: the D365 barcode is carried even when DIM_PRODUCT lacks the UPC (EDW-134), so the miss is diagnosable from the fact
        , pr.sku
        , wh.warehouse_key
        , wh.warehouse_id
        , coalesce(st.availability_class, 'UNKNOWN') as availability_status_primary
        , pc.standard_cost_unit
        , pc.cost_currency_code
        , pcl.landed_cost_unit
        , opo.on_order_qty
        , git.in_transit_inbound_qty
        , tit.in_transit_transfer_qty
        , dd.date_key as snapshot_date_key
        , pp.list_price_usd
        , ls.last_sale_date

        -- EDW-46 fan-out guard: on_order/in-transit are item+warehouse-level supply
        -- quantities, but 91% of item+warehouse combos carry >1 status row (confirmed
        -- live 2026-09-10) -- a naive join repeats the same total on every status row and
        -- overstates it on summation. Rank rows per item+warehouse (AVAILABLE status
        -- first, else deterministic tie-break) and only the rank-1 row gets the qty below.
        , row_number() over (
            partition by oh.ItemID, oh.INVENTSIZEID, oh.INVENTCOLORID, oh.INVENTLOCATIONID, oh.inventsiteid
            order by case when coalesce(st.availability_class, 'UNKNOWN') = 'AVAILABLE' then 0 else 1 end, oh.inventory_status_code
          ) as item_warehouse_supply_rank

        -- lifecycle_status_code (spec 2.2, rule revised at EDW-117 item 10, v2.6):
        -- precedence CLEARANCE -> NEW -> CORE -> NULL. DIM_PRODUCT.Vintage is the
        -- product master's carryover flag (true on 8,867 of 20,497 current SKUs,
        -- including 4,273 that debuted since July 2024, and on 7,461 Active / In
        -- Production SKUs holding 55 percent of stocked units) -- that population is the
        -- continuing line, i.e. CORE, not an aged tier. VINTAGE is retired from the
        -- domain until Merchandising defines it; the v2.5 rule mislabelled 1.4M units.
        -- NULL only when the product join itself misses.
        , case
            when pr.product_key is null then null
            when pr.erp_status = 'Sell_to_0' then 'CLEARANCE'
            when pr.plm_status = 'Dropped' and oh.on_hand_qty > 0 then 'CLEARANCE'
            when pr.debut_date is not null
                and pr.debut_date >= date_add(oh.snapshot_date, -365)
                and pr.debut_date <= oh.snapshot_date then 'NEW'
            when pr.erp_status is null and pr.plm_status is null and pr.debut_date is null then null
            else 'CORE'
          end as lifecycle_status_code

    from on_hand_agg oh
    -- EDW-117 item 1: barcode path. Variant -> UPC -> DIM_PRODUCT current row.
    left join product_barcode pb
        on oh.ItemID = pb.ITEMID
        and oh.INVENTSIZEID = pb.INVENTSIZEID
        and oh.INVENTCOLORID = pb.INVENTCOLORID
    left join product pr
        on pb.upc = pr.upc
    left join warehouse wh
        on oh.INVENTLOCATIONID = wh.warehouse_id
        and oh.inventsiteid = wh.d365_site_id
    left join inventory_status st
        on oh.inventory_status_code = st.inventory_status_code
    -- EDW-94 A1: join on product_id, not product_key -- product_key on the cost fact
    -- carries one arbitrary UPC per item and is not a relationship key; the old join
    -- left 92% of stocked units (2.34M of 2.54M) without a standard cost.
    left join product_cost pc
        on oh.ItemID = pc.product_id
    left join product_cost_landed pcl
        on oh.ItemID = pcl.product_id
    left join open_po_agg opo
        on oh.ItemID = opo.ITEMID
        and oh.INVENTSIZEID = opo.INVENTSIZEID
        and oh.INVENTCOLORID = opo.INVENTCOLORID
        and oh.INVENTLOCATIONID = opo.INVENTLOCATIONID
        and oh.inventsiteid = opo.inventsiteid
    left join goods_in_transit_agg git
        on oh.ItemID = git.ITEMID
        and oh.INVENTSIZEID = git.INVENTSIZEID
        and oh.INVENTCOLORID = git.INVENTCOLORID
        and oh.INVENTLOCATIONID = git.INVENTLOCATIONID
        and oh.inventsiteid = git.inventsiteid
    left join transfer_in_transit_agg tit
        on oh.ItemID = tit.ITEMID
        and oh.INVENTSIZEID = tit.INVENTSIZEID
        and oh.INVENTCOLORID = tit.INVENTCOLORID
        and oh.INVENTLOCATIONID = tit.INVENTLOCATIONID
        and oh.inventsiteid = tit.inventsiteid
    left join snapshot_date_dim dd
        on dd.Date = oh.snapshot_date
    left join product_price pp
        on pr.product_key = pp.product_key
    left join last_sale_agg ls
        on pr.product_key = ls.product_key
        and wh.warehouse_key = ls.warehouse_key

),

{% if not is_incremental() %}
backfill_raw as (

    select

          UPC
        , WarehouseId
        , coalesce(nullif(InventoryStatus, ''), 'UNKNOWN') as inventory_status_code  -- sign-off fix, same rule as inventory_dim above -- fact-wide, not just the native branch
        , InventoryQuantity
        , InventoryAmount
        , UnitCost
        , SnapshotDate

    from {{ ref('silver_kpi_inventory_value') }}
    where SnapshotDate >= '2024-06-30'
      and SnapshotDate < {{ inventory_snapshot_native_start_date() }}  -- fixed seam (spec 2.5 rule 4), never a runtime bound. EDW-117 item 2: 2026-09-01, prod's first native day; Aug 21-31 were inserted in place from this source (see the EDW-117 runbook), which is why this literal and prod history agree.

),

backfill_joined as (

    select

          b.*
        , pr.product_key
        , pr.style_number
        , pr.sku
        , wh.warehouse_key
        , wh.d365_site_id
        , coalesce(st.availability_class, 'UNKNOWN') as availability_status_primary
        , pc.cost_currency_code
        , dd.date_key as snapshot_date_key

        -- lifecycle_status_code: same v2.6 rule as the native branch (VINTAGE retired) --
        -- "on-hand remaining" reads the backfill row's own quantity.
        , case
            when pr.product_key is null then null
            when pr.erp_status = 'Sell_to_0' then 'CLEARANCE'
            when pr.plm_status = 'Dropped' and b.InventoryQuantity > 0 then 'CLEARANCE'
            when pr.debut_date is not null
                and pr.debut_date >= date_add(b.SnapshotDate, -365)
                and pr.debut_date <= b.SnapshotDate then 'NEW'
            when pr.erp_status is null and pr.plm_status is null and pr.debut_date is null then null
            else 'CORE'
          end as lifecycle_status_code

    from backfill_raw b
    left join product pr
        on b.UPC = pr.upc
    left join warehouse wh
        on b.WarehouseId = wh.warehouse_id
    left join inventory_status st
        on b.inventory_status_code = st.inventory_status_code
    -- EDW-94 A1: join on product_id -- fact_product_cost is item-grain; product_key
    -- here is an arbitrary single UPC per item, not a relationship key.
    left join product_cost pc
        on pr.style_number = pc.product_id
    left join snapshot_date_dim dd
        on dd.Date = b.SnapshotDate

),
{% endif %}

final as (

    select

    -- Core ID
          xxhash64(j.snapshot_date, j.ItemID, j.INVENTSIZEID, j.INVENTCOLORID, j.INVENTLOCATIONID, coalesce(j.inventsiteid, ''), coalesce(j.inventory_status_code, '')) as inventory_snapshot_key  -- EDW-117 item 4: inventsiteid added (spec grain carries site through warehouse_key); changes keys for new days only, history is never re-keyed
        , j.snapshot_date_key
        , j.snapshot_date
        , j.product_key
        , j.ItemID                              as product_id
        , j.upc
        , j.sku
        , j.warehouse_key
        , j.warehouse_id
        , j.inventory_status_code
        , 'D365'                                as source_system

    -- Quantities
        , j.on_hand_qty
        , j.available_qty                       -- native InventSum.AVAILPHYSICAL (D365's own computed value), not the spec's literal subtraction formula -- allocated/hold/damaged aren't sourced (see below), and this matched the subtraction result within 0.03% when validated live
        , j.reserved_qty
        , cast(null as decimal(18,4)) as allocated_qty  -- Source once available: no column identified on InventSum/InventDim
        , cast(null as decimal(18,4)) as damaged_qty  -- Source once available: no column identified on InventSum/InventDim
        , cast(null as decimal(18,4)) as hold_qty  -- Blocked/hold state is carried via inventory_status_code, not a separate quantity measure on these tables
        , case when j.item_warehouse_supply_rank = 1 then coalesce(j.in_transit_inbound_qty, 0) else 0 end as in_transit_inbound_qty  -- Phase 2 per spec -- sourced 2026-09-10, see goods_in_transit_agg above (EDW-46); supply_rank guard above prevents double counting across status rows
        , case when j.item_warehouse_supply_rank = 1 then coalesce(j.in_transit_transfer_qty, 0) else 0 end as in_transit_transfer_qty  -- Phase 2 per spec -- sourced 2026-09-10, see transfer_in_transit_agg above (EDW-46) -- reads 0 today, source table has no live rows yet
        , case when j.item_warehouse_supply_rank = 1 then coalesce(j.on_order_qty, 0) else 0 end as on_order_qty  -- Phase 2 per spec -- sourced 2026-09-10, see open_po_agg above (EDW-46); supply_rank guard above prevents double counting across status rows
        , cast(null as decimal(18,4)) as reorder_point_qty  -- Phase 2 per spec -- EDW-46: no D365 item-coverage export exists anywhere in the warehouse yet (confirmed via a full dwhvisualnext table scan, 2026-09-10) -- needs a new BYOD export, pair with D365 admin per EDW-46's own scope note
        , cast(null as decimal(18,4)) as safety_stock_qty  -- Phase 2 per spec -- EDW-46: same gap as reorder_point_qty, no source table exists yet
        , cast(null as decimal(18,4)) as backorder_qty  -- Source once available: no column identified
        , cast(null as string) as qty_uom  -- Source once available: no UOM column identified on these tables

    -- Costs
        , j.standard_cost_unit
        , j.on_hand_qty * j.standard_cost_unit  as standard_cost_amount
        , j.landed_cost_unit  -- Phase 2 per spec -- sourced 2026-09-10 from fact_product_cost (cost_type='LANDED', is_current=true), PLM-estimate coverage only today (EDW-12) -- null where fact_product_cost has no LANDED row yet (~26% of products)
        , j.on_hand_qty * j.landed_cost_unit as landed_cost_amount  -- Phase 2 per spec -- null when landed_cost_unit is null
        , (j.on_hand_qty * j.landed_cost_unit) - (j.on_hand_qty * j.standard_cost_unit) as cost_variance_amount  -- Phase 2 per spec -- spec 2.3 derived rule: landed_cost_amount - standard_cost_amount
        , cast(j.on_hand_qty * j.list_price_usd as decimal(19,4)) as retail_value_amount  -- EDW-49: v_product_price_current.list_price_usd on product_key; null where the variant has no current USD list price
        , j.available_qty * j.standard_cost_unit as available_cost_amount
        , cast(null as decimal(19,4)) as damaged_cost_amount  -- = damaged_qty x standard_cost_unit once damaged_qty is sourced
        , j.cost_currency_code

    -- Status
        , j.lifecycle_status_code
        , j.availability_status_primary
        , j.inventsiteid                        as inventory_site_id

    -- Aging
        , cast(null as date) as first_receipt_date  -- Source once available: min(movement_datetime) from fact_inventory_movement where movement_type = 'RECEIPT'
        , cast(null as date) as last_receipt_date  -- Source once available: max(movement_datetime) from fact_inventory_movement where movement_type = 'RECEIPT'
        , cast(null as int) as days_on_hand_age  -- Source once available: depends on first/last_receipt_date above
        , cast(null as string) as age_bucket  -- Source once available: depends on days_on_hand_age above
        , j.last_sale_date  -- EDW-49: max non-return invoice_date per product_key + warehouse_key; null where never sold from this warehouse

    -- Audit
        , {{ inventory_snapshot_branch_label('native') }} as record_source_table  -- EDW-117 item 5: branch constant
        , current_timestamp()                   as etl_insert_datetime
        , current_timestamp()                   as etl_update_datetime
        , sha2(
            concat_ws('||',
                coalesce(cast(j.on_hand_qty as string), ''),
                coalesce(cast(j.reserved_qty as string), ''),
                coalesce(cast(j.available_qty as string), ''),
                coalesce(j.inventory_status_code, '')
            ), 256
          )                                      as row_hash

    from joined j
    -- EDW-117 item 3 (spec 2.1 / 2.3 v2.6): a native row is a position only if some quantity
    -- measure is non-zero. InventSum keeps every dimension combination ever touched (85
    -- percent of rows all-zero on 2026-09-22). Supply-only positions (zero on hand, open PO
    -- or in-transit quantity on the rank-1 status row) ARE kept: on 2026-09-22 they carried
    -- 372,243 on-order and 105,662 in-transit units, 44 percent of all on-order, which the
    -- narrower on-hand-only filter in the ticket text would have dropped.
    where not (
            coalesce(j.on_hand_qty, 0) = 0
        and coalesce(j.reserved_qty, 0) = 0
        and coalesce(j.available_qty, 0) = 0
        and coalesce(case when j.item_warehouse_supply_rank = 1 then j.on_order_qty end, 0) = 0
        and coalesce(case when j.item_warehouse_supply_rank = 1 then j.in_transit_inbound_qty end, 0) = 0
        and coalesce(case when j.item_warehouse_supply_rank = 1 then j.in_transit_transfer_qty end, 0) = 0
    )

    {% if not is_incremental() %}
    union all

    select

    -- Core ID
          xxhash64(b.SnapshotDate, b.UPC, b.WarehouseId, coalesce(b.inventory_status_code, '')) as inventory_snapshot_key
        , b.snapshot_date_key
        , b.SnapshotDate                        as snapshot_date
        , b.product_key
        , b.style_number                        as product_id
        , b.UPC                                 as upc
        , b.sku
        , b.warehouse_key
        , b.WarehouseId                         as warehouse_id
        , b.inventory_status_code
        , 'D365'                                as source_system

    -- Quantities
        , b.InventoryQuantity                   as on_hand_qty
        , cast(null as decimal(18,4)) as available_qty  -- Source once available: no reserved/available breakdown on f_KPI_InventoryValue
        , cast(null as decimal(18,4)) as reserved_qty  -- Source once available: no reserved/available breakdown on f_KPI_InventoryValue
        , cast(null as decimal(18,4)) as allocated_qty  -- Source once available: no column on f_KPI_InventoryValue
        , cast(null as decimal(18,4)) as damaged_qty  -- Source once available: no column on f_KPI_InventoryValue
        , cast(null as decimal(18,4)) as hold_qty  -- Blocked/hold state carried via inventory_status_code
        , cast(null as decimal(18,4)) as in_transit_inbound_qty  -- Phase 2 per spec -- EDW-46 sources (PurchLine/GoodsInTransit) reflect today's live D365 state only, no historical grain to backfill against
        , cast(null as decimal(18,4)) as in_transit_transfer_qty  -- Phase 2 per spec -- same reason as in_transit_inbound_qty above
        , cast(null as decimal(18,4)) as on_order_qty  -- Phase 2 per spec -- same reason as in_transit_inbound_qty above
        , cast(null as decimal(18,4)) as reorder_point_qty  -- Phase 2 per spec -- EDW-46: no source table exists yet (see native branch note)
        , cast(null as decimal(18,4)) as safety_stock_qty  -- Phase 2 per spec -- source has SafetyStock but withheld to match Phase 1 scope of the native rows
        , cast(null as decimal(18,4)) as backorder_qty  -- Source once available: no column on f_KPI_InventoryValue
        , cast(null as string) as qty_uom  -- Source once available: no UOM column on f_KPI_InventoryValue

    -- Costs
        , b.UnitCost                             as standard_cost_unit  -- legacy report's own historical unit cost, not fact_product_cost's current-only cost
        , b.InventoryAmount                      as standard_cost_amount -- legacy report's own precomputed on-hand value, not recomputed, avoids rounding drift against its source
        , cast(null as decimal(19,4)) as landed_cost_unit  -- Phase 2 per spec -- fact_product_cost is current-only, no historical landed cost to backfill against
        , cast(null as decimal(19,4)) as landed_cost_amount  -- Phase 2 per spec -- same reason as landed_cost_unit above
        , cast(null as decimal(19,4)) as cost_variance_amount  -- Phase 2 per spec -- same reason as landed_cost_unit above
        , cast(null as decimal(19,4)) as retail_value_amount  -- native branch only: current price, no historical price grain
        , cast(null as decimal(19,4)) as available_cost_amount  -- Source once available: depends on available_qty above
        , cast(null as decimal(19,4)) as damaged_cost_amount  -- Source once available: depends on damaged_qty above
        , b.cost_currency_code

    -- Status
        , b.lifecycle_status_code
        , b.availability_status_primary
        , b.d365_site_id                        as inventory_site_id

    -- Aging
        , cast(null as date) as first_receipt_date  -- Source once available: same plan as native rows
        , cast(null as date) as last_receipt_date  -- Source once available: same plan as native rows
        , cast(null as int) as days_on_hand_age  -- Source once available: same plan as native rows
        , cast(null as string) as age_bucket  -- Source once available: same plan as native rows
        , cast(null as date) as last_sale_date  -- native branch only: current-state MAX, not point-in-time

    -- Audit
        , {{ inventory_snapshot_branch_label('backfill') }} as record_source_table  -- EDW-117 item 5: branch constant
        , current_timestamp()                   as etl_insert_datetime
        , current_timestamp()                   as etl_update_datetime
        , sha2(
            concat_ws('||',
                coalesce(cast(b.InventoryQuantity as string), ''),
                '',
                '',
                coalesce(b.inventory_status_code, '')
            ), 256
          )                                      as row_hash

    from backfill_joined b
    {% endif %}

)

select * from final
