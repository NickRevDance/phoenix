{{ config(severity = 'warn') }}

-- EDW-183 (Inventory spec 5.9): the month-end view carries the certified scope of
-- V_METRICS_INVENTORY_DAILY (company-owned statuses, made-to-order out on product_id and UPC),
-- so on each close date the two hold the same snapshot rows, once each. Returns each row that is
-- in one and not the other, and each close date whose row counts differ (a duplicated row); a
-- difference means the two scope rules have drifted apart or a join fanned out.

with month_end as (

    select close_snapshot_date as snapshot_date, inventory_snapshot_key
    from {{ ref('v_inventory_value_month_end') }}

),

metrics_daily as (

    select m.snapshot_date, m.inventory_snapshot_key
    from {{ ref('v_metrics_inventory_daily') }} m
    where m.snapshot_date in (select distinct snapshot_date from month_end)

),

month_end_counts as (

    select snapshot_date, count(*) as row_count
    from month_end
    group by 1

),

metrics_daily_counts as (

    select snapshot_date, count(*) as row_count
    from metrics_daily
    group by 1

)

select
      'in v_inventory_value_month_end, not in v_metrics_inventory_daily' as failure
    , e.snapshot_date
    , cast(e.inventory_snapshot_key as string) as detail
from month_end e
left anti join metrics_daily m
    on m.snapshot_date = e.snapshot_date
    and m.inventory_snapshot_key = e.inventory_snapshot_key

union all

select
      'in v_metrics_inventory_daily, not in v_inventory_value_month_end'
    , m.snapshot_date
    , cast(m.inventory_snapshot_key as string)
from metrics_daily m
left anti join month_end e
    on m.snapshot_date = e.snapshot_date
    and m.inventory_snapshot_key = e.inventory_snapshot_key

union all

select
      'row count differs on the close date'
    , e.snapshot_date
    , concat(cast(e.row_count as string), ' in v_inventory_value_month_end, ', cast(coalesce(m.row_count, 0) as string), ' in v_metrics_inventory_daily')
from month_end_counts e
left join metrics_daily_counts m
    on m.snapshot_date = e.snapshot_date
where e.row_count <> coalesce(m.row_count, 0)