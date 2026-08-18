{{ config(materialized = 'table') }}

-- Legacy daily inventory snapshot report (pre-dates this project's D365 pipeline).
-- Only source of real inventory history -- InventSum/InventDim are current-balance-only.
-- Excludes SnapshotDate = current_date(): that day is still loading intraday and the
-- native pipeline owns "today" going forward anyway.

select

      FactId
    , ProductDimId
    , WarehouseId
    , DateId
    , UPC
    , InventoryQuantity
    , InventoryAmount
    , SafetyStock
    , QtySold
    , SalesQty28D
    , SalesAmt28D
    , UnitCost
    , AvgWeeklySales
    , WOC
    , SnapshotDate
    , InventoryStatus

from {{ ref('bronze_kpi_inventory_value') }}
where SnapshotDate < current_date()
