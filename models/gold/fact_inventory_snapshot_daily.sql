{{ config(
    materialized = 'incremental',
    unique_key = 'inventory_snapshot_key',
    incremental_strategy = 'merge'
) }}

-- NEEDS CONFIRMATION: incremental/merge so this fact accumulates real daily history
-- (spec grain includes snapshot_date_key) instead of being overwritten every run.
-- Ongoing rows are always native InventSum/InventDim, stamped current_date().
-- History before the native pipeline existed (2024-06-30 through yesterday) is
-- backfilled from the legacy analytics.f_KPI_InventoryValue report, one time only,
-- via is_incremental() below -- it only runs on the first build or a --full-refresh,
-- never on normal incremental runs. A --full-refresh will re-scan and re-merge all
-- ~6.2M backfill rows again; that's correct but not free, budget for it.

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

    from {{ ref('silver_byod_inventory_sum') }}

),

inventory_dim as (

    select

          InventDimID
        , nullif(INVENTSTATUSID, '') as inventory_status_code

    from {{ ref('silver_byod_inventory_dim') }}

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
    group by 1, 2, 3, 4, 5, 6

),

product as (

    select

          product_key
        , upc
        , sku
        , style_number
        , size
        , d365_color_code

    from {{ ref('dim_product') }}
    where version_number = 1

),

warehouse as (

    select

          warehouse_key
        , warehouse_id
        , d365_site_id

    from {{ ref('dim_warehouse') }}

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

          product_key
        , standard_cost_unit
        , cost_currency_code

    from {{ ref('fact_product_cost') }}

),

snapshot_date_dim as (

    select

          DateId
        , Date

    from {{ ref('dim_date') }}

),

joined as (

    select

          oh.*
        , pr.product_key
        , pr.upc
        , pr.sku
        , wh.warehouse_key
        , wh.warehouse_id
        , coalesce(st.availability_class, 'UNKNOWN') as availability_status_primary
        , pc.standard_cost_unit
        , pc.cost_currency_code
        , dd.DateId as snapshot_date_key

    from on_hand_agg oh
    left join product pr
        on oh.ItemID = pr.style_number
        and oh.INVENTSIZEID = pr.size
        and oh.INVENTCOLORID = pr.d365_color_code
    left join warehouse wh
        on oh.INVENTLOCATIONID = wh.warehouse_id
        and oh.inventsiteid = wh.d365_site_id
    left join inventory_status st
        on oh.inventory_status_code = st.inventory_status_code
    left join product_cost pc
        on pr.product_key = pc.product_key
    left join snapshot_date_dim dd
        on dd.Date = oh.snapshot_date

),

{% if not is_incremental() %}
backfill_raw as (

    select

          UPC
        , WarehouseId
        , nullif(InventoryStatus, '') as inventory_status_code
        , InventoryQuantity
        , InventoryAmount
        , UnitCost
        , SnapshotDate

    from {{ ref('silver_kpi_inventory_value') }}
    where SnapshotDate >= '2024-06-30'

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
        , dd.DateId as snapshot_date_key

    from backfill_raw b
    left join product pr
        on b.UPC = pr.upc
    left join warehouse wh
        on b.WarehouseId = wh.warehouse_id
    left join inventory_status st
        on b.inventory_status_code = st.inventory_status_code
    left join product_cost pc
        on pr.product_key = pc.product_key
    left join snapshot_date_dim dd
        on dd.Date = b.SnapshotDate

),
{% endif %}

final as (

    select

    -- Core ID
          xxhash64(j.snapshot_date, j.ItemID, j.INVENTSIZEID, j.INVENTCOLORID, j.INVENTLOCATIONID, coalesce(j.inventory_status_code, '')) as inventory_snapshot_key
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
        , null allocated_qty                    -- Source once available: no column identified on InventSum/InventDim
        , null damaged_qty                      -- Source once available: no column identified on InventSum/InventDim
        , null hold_qty                         -- Blocked/hold state is carried via inventory_status_code, not a separate quantity measure on these tables
        , null in_transit_inbound_qty           -- Phase 2 per spec
        , null in_transit_transfer_qty          -- Phase 2 per spec
        , null on_order_qty                     -- Phase 2 per spec -- source (InventSum.ONORDER) already exists on silver_byod_inventory_sum, not selected yet
        , null reorder_point_qty                -- Phase 2 per spec
        , null safety_stock_qty                 -- Phase 2 per spec
        , null backorder_qty                    -- Source once available: no column identified
        , null qty_uom                          -- Source once available: no UOM column identified on these tables

    -- Costs
        , j.standard_cost_unit
        , j.on_hand_qty * j.standard_cost_unit  as standard_cost_amount
        , null landed_cost_unit                 -- Phase 2 per spec -- source already exists on fact_product_cost.landed_cost_unit
        , null landed_cost_amount               -- Phase 2 per spec
        , null cost_variance_amount             -- Phase 2 per spec
        , null retail_value_amount              -- Phase 2 per spec
        , j.available_qty * j.standard_cost_unit as available_cost_amount
        , null damaged_cost_amount              -- = damaged_qty x standard_cost_unit once damaged_qty is sourced
        , j.cost_currency_code

    -- Status
        , null lifecycle_status_code            -- NEEDS CONFIRMATION -- no single lifecycle-status source identified (dim_product carries plm_status/erp_status separately)
        , j.availability_status_primary
        , j.inventsiteid                        as inventory_site_id

    -- Aging
        , null first_receipt_date               -- Source once available: min(movement_datetime) from fact_inventory_movement where movement_type = 'RECEIPT'
        , null last_receipt_date                -- Source once available: max(movement_datetime) from fact_inventory_movement where movement_type = 'RECEIPT'
        , null days_on_hand_age                 -- Source once available: depends on first/last_receipt_date above
        , null age_bucket                       -- Source once available: depends on days_on_hand_age above
        , null last_sale_date                   -- Phase 2 per spec

    -- Audit
        , 'silver_byod_inventory_sum + silver_byod_inventory_dim' as record_source_table
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
        , null available_qty                    -- Source once available: no reserved/available breakdown on f_KPI_InventoryValue
        , null reserved_qty                     -- Source once available: no reserved/available breakdown on f_KPI_InventoryValue
        , null allocated_qty                    -- Source once available: no column on f_KPI_InventoryValue
        , null damaged_qty                      -- Source once available: no column on f_KPI_InventoryValue
        , null hold_qty                         -- Blocked/hold state carried via inventory_status_code
        , null in_transit_inbound_qty           -- Phase 2 per spec
        , null in_transit_transfer_qty          -- Phase 2 per spec
        , null on_order_qty                     -- Phase 2 per spec
        , null reorder_point_qty                -- Phase 2 per spec
        , null safety_stock_qty                 -- Phase 2 per spec -- source has SafetyStock but withheld to match Phase 1 scope of the native rows
        , null backorder_qty                    -- Source once available: no column on f_KPI_InventoryValue
        , null qty_uom                          -- Source once available: no UOM column on f_KPI_InventoryValue

    -- Costs
        , b.UnitCost                             as standard_cost_unit  -- legacy report's own historical unit cost, not fact_product_cost's current-only cost
        , b.InventoryAmount                      as standard_cost_amount -- legacy report's own precomputed on-hand value, not recomputed, avoids rounding drift against its source
        , null landed_cost_unit                 -- Phase 2 per spec
        , null landed_cost_amount               -- Phase 2 per spec
        , null cost_variance_amount             -- Phase 2 per spec
        , null retail_value_amount              -- Phase 2 per spec
        , null available_cost_amount            -- Source once available: depends on available_qty above
        , null damaged_cost_amount              -- Source once available: depends on damaged_qty above
        , b.cost_currency_code

    -- Status
        , null lifecycle_status_code            -- NEEDS CONFIRMATION, same as native rows
        , b.availability_status_primary
        , b.d365_site_id                        as inventory_site_id

    -- Aging
        , null first_receipt_date               -- Source once available: same plan as native rows
        , null last_receipt_date                -- Source once available: same plan as native rows
        , null days_on_hand_age                 -- Source once available: same plan as native rows
        , null age_bucket                       -- Source once available: same plan as native rows
        , null last_sale_date                   -- Phase 2 per spec

    -- Audit
        , 'silver_kpi_inventory_value'          as record_source_table
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
