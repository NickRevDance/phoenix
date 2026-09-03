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

    from {{ ref('silver_d365_inventory_sum') }}

),

inventory_dim as (

    select

          InventDimID
        , coalesce(nullif(INVENTSTATUSID, ''), 'UNKNOWN') as inventory_status_code  -- sign-off fix (spec 2.3 rule): was nullif-only, leaving blank statuses as NULL in the grain column instead of routing them to the UNKNOWN member per the EDW-7 unknown-mapping pattern

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
        , erp_status
        , plm_status
        , Vintage
        , debut_date

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
    where is_current = true
      and cost_type = 'STANDARD'  -- bug fix 2026-09-03: fact_product_cost is grained by cost_type x effective_date (insert-only accumulating history, rebuilt 2026-09-01) -- an unfiltered join here fans every inventory row out to one source row per cost_type/effective_date version, which broke the incremental MERGE (DELTA_MULTIPLE_SOURCE_ROW_MATCHING_TARGET_ROW_IN_MERGE) once fact_product_cost accumulated more than one row per product_key

),

snapshot_date_dim as (

    select

          date_key
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
        , dd.date_key as snapshot_date_key

        -- lifecycle_status_code (sign-off fix, replaces the NEEDS CONFIRMATION null):
        -- precedence CLEARANCE -> VINTAGE -> NEW -> CORE -> NULL, confirmed against
        -- the live distribution 2026-08-27 (52,624 VINTAGE / 33,806 CLEARANCE / 8,165
        -- NEW / 3,174 CORE / 10,576 NULL on the then-latest snapshot). NULL only when
        -- the product join itself misses (dim_product's own inputs have 100% coverage
        -- today, so the "all inputs null" branch is dead code in practice but kept for
        -- when a future product genuinely has none of them populated).
        , case
            when pr.product_key is null then null
            when pr.erp_status = 'Sell_to_0' then 'CLEARANCE'
            when pr.plm_status = 'Dropped' and oh.on_hand_qty > 0 then 'CLEARANCE'
            when pr.Vintage = true then 'VINTAGE'
            when pr.debut_date is not null
                and pr.debut_date >= date_add(oh.snapshot_date, -365)
                and pr.debut_date <= oh.snapshot_date then 'NEW'
            when pr.erp_status is null and pr.plm_status is null and pr.Vintage is null and pr.debut_date is null then null
            else 'CORE'
          end as lifecycle_status_code

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
        , coalesce(nullif(InventoryStatus, ''), 'UNKNOWN') as inventory_status_code  -- sign-off fix, same rule as inventory_dim above -- fact-wide, not just the native branch
        , InventoryQuantity
        , InventoryAmount
        , UnitCost
        , SnapshotDate

    from {{ ref('silver_kpi_inventory_value') }}
    where SnapshotDate >= '2024-06-30'
      and SnapshotDate < '2026-08-21'  -- sign-off fix: fixed literal, not a runtime bound. Confirmed live 2026-08-27: native branch's first date is 2026-08-21 (min(snapshot_date) where record_source_table = 'silver_d365_inventory_sum + silver_d365_inventory_dim'). Was previously bounded only by silver_kpi_inventory_value's own `< current_date()` filter, which drifts forward every day -- a --full-refresh run today would already pull 2026-08-21 through yesterday from both branches at once, double-counting those days. Update this literal only if the native pipeline's confirmed start date changes.

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

        -- lifecycle_status_code: same rule as the native branch above (fact-wide, not
        -- native-only) -- "on-hand remaining" reads the backfill row's own quantity.
        , case
            when pr.product_key is null then null
            when pr.erp_status = 'Sell_to_0' then 'CLEARANCE'
            when pr.plm_status = 'Dropped' and b.InventoryQuantity > 0 then 'CLEARANCE'
            when pr.Vintage = true then 'VINTAGE'
            when pr.debut_date is not null
                and pr.debut_date >= date_add(b.SnapshotDate, -365)
                and pr.debut_date <= b.SnapshotDate then 'NEW'
            when pr.erp_status is null and pr.plm_status is null and pr.Vintage is null and pr.debut_date is null then null
            else 'CORE'
          end as lifecycle_status_code

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
        , cast(null as decimal(18,4)) as allocated_qty  -- Source once available: no column identified on InventSum/InventDim
        , cast(null as decimal(18,4)) as damaged_qty  -- Source once available: no column identified on InventSum/InventDim
        , cast(null as decimal(18,4)) as hold_qty  -- Blocked/hold state is carried via inventory_status_code, not a separate quantity measure on these tables
        , cast(null as decimal(18,4)) as in_transit_inbound_qty  -- Phase 2 per spec
        , cast(null as decimal(18,4)) as in_transit_transfer_qty  -- Phase 2 per spec
        , cast(null as decimal(18,4)) as on_order_qty  -- Phase 2 per spec -- source (InventSum.ONORDER) already exists on silver_d365_inventory_sum, not selected yet
        , cast(null as decimal(18,4)) as reorder_point_qty  -- Phase 2 per spec
        , cast(null as decimal(18,4)) as safety_stock_qty  -- Phase 2 per spec
        , cast(null as decimal(18,4)) as backorder_qty  -- Source once available: no column identified
        , cast(null as string) as qty_uom  -- Source once available: no UOM column identified on these tables

    -- Costs
        , j.standard_cost_unit
        , j.on_hand_qty * j.standard_cost_unit  as standard_cost_amount
        , cast(null as decimal(19,4)) as landed_cost_unit  -- Phase 2 per spec -- source already exists on fact_product_cost.landed_cost_unit
        , cast(null as decimal(19,4)) as landed_cost_amount  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as cost_variance_amount  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as retail_value_amount  -- Phase 2 per spec
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
        , cast(null as date) as last_sale_date  -- Phase 2 per spec

    -- Audit
        , 'silver_d365_inventory_sum + silver_d365_inventory_dim' as record_source_table
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
        , cast(null as decimal(18,4)) as available_qty  -- Source once available: no reserved/available breakdown on f_KPI_InventoryValue
        , cast(null as decimal(18,4)) as reserved_qty  -- Source once available: no reserved/available breakdown on f_KPI_InventoryValue
        , cast(null as decimal(18,4)) as allocated_qty  -- Source once available: no column on f_KPI_InventoryValue
        , cast(null as decimal(18,4)) as damaged_qty  -- Source once available: no column on f_KPI_InventoryValue
        , cast(null as decimal(18,4)) as hold_qty  -- Blocked/hold state carried via inventory_status_code
        , cast(null as decimal(18,4)) as in_transit_inbound_qty  -- Phase 2 per spec
        , cast(null as decimal(18,4)) as in_transit_transfer_qty  -- Phase 2 per spec
        , cast(null as decimal(18,4)) as on_order_qty  -- Phase 2 per spec
        , cast(null as decimal(18,4)) as reorder_point_qty  -- Phase 2 per spec
        , cast(null as decimal(18,4)) as safety_stock_qty  -- Phase 2 per spec -- source has SafetyStock but withheld to match Phase 1 scope of the native rows
        , cast(null as decimal(18,4)) as backorder_qty  -- Source once available: no column on f_KPI_InventoryValue
        , cast(null as string) as qty_uom  -- Source once available: no UOM column on f_KPI_InventoryValue

    -- Costs
        , b.UnitCost                             as standard_cost_unit  -- legacy report's own historical unit cost, not fact_product_cost's current-only cost
        , b.InventoryAmount                      as standard_cost_amount -- legacy report's own precomputed on-hand value, not recomputed, avoids rounding drift against its source
        , cast(null as decimal(19,4)) as landed_cost_unit  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as landed_cost_amount  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as cost_variance_amount  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as retail_value_amount  -- Phase 2 per spec
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
        , cast(null as date) as last_sale_date  -- Phase 2 per spec

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
