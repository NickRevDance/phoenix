-- EDW-126: safety_stock_qty on the latest native snapshot ties to the reflection feed load it was
-- built from (spec 2.6, decision I2a: reconciles within 0 units). Returns a row per covered
-- site + location + barcode whose snapshot total differs from the feed. Barcodes with no snapshot
-- row are not checked here: a position with zero quantity everywhere is not a row (spec 2.1).

with latest as (

    select max(f.snapshot_date) as snapshot_date
    from {{ ref('fact_inventory_snapshot_daily') }} f
    where f.record_source_table = {{ inventory_snapshot_branch_label('native') }}

),

snapshot_side as (

    select

          f.upc
        , f.warehouse_id
        , f.inventory_site_id
        , sum(f.safety_stock_qty) as snapshot_safety_stock_qty

    from {{ ref('fact_inventory_snapshot_daily') }} f
    inner join latest l
        on f.snapshot_date = l.snapshot_date
    where f.record_source_table = {{ inventory_snapshot_branch_label('native') }}
    group by 1, 2, 3

)

select

      c.upc
    , c.warehouse_id
    , c.inventory_site_id
    , c.safety_stock_qty as feed_safety_stock_qty
    , s.snapshot_safety_stock_qty

from {{ ref('silver_reflection_item_coverage') }} c
inner join snapshot_side s
    on c.upc = s.upc
    and c.warehouse_id = s.warehouse_id
    and c.inventory_site_id = s.inventory_site_id
where s.snapshot_safety_stock_qty is distinct from c.safety_stock_qty
