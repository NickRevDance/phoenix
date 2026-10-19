{{ config(materialized = 'table') }}

-- D365 item coverage safety stock as delivered by the legacy reflection feed (decision I2a),
-- the source of record until a BYOD item-coverage entity exists. One row per site + location +
-- barcode from the latest feed load. Only a maintained value (SafetyStock > 0) is a row: the
-- feed cannot tell an unset threshold from a zero, and uncovered items carry NULL, never 0 (I2b).

with latest_load as (

    select max(SnapshotDateTime) as snapshot_datetime
    from {{ ref('bronze_reflection_inventory_onhand') }}

)

select

      r.Warehouse                    as inventory_site_id
    , r.InventoryType                as warehouse_id
    , r.Barcode                      as upc
    , max(r.SafetyStock)             as safety_stock_qty
    , max(r.SnapshotDateTime)        as feed_snapshot_datetime

from {{ ref('bronze_reflection_inventory_onhand') }} r
inner join latest_load l
    on r.SnapshotDateTime = l.snapshot_datetime
where r.SafetyStock > 0
  and nullif(trim(r.Barcode), '') is not null
group by 1, 2, 3
