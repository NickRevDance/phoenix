-- EDW-144 (Inventory spec Section 5, stocking-policy rule): the certified inventory views
-- hold stocked items only, and the rule removes nothing else. Returns a row for each check
-- that fails:
--   1. a MADE_TO_ORDER item present in v_current_inventory or on the latest day of
--      v_metrics_inventory_daily;
--   2. v_current_inventory not equal, in rows or on-hand units, to the latest day of the fact
--      filtered the same way (company-owned statuses, stocked items).

with made_to_order as (

    select product_id
    from {{ ref('ref_stocking_policy') }}
    where stocking_policy = 'MADE_TO_ORDER'

),

latest as (

    select max(snapshot_date) as snapshot_date
    from {{ ref('fact_inventory_snapshot_daily') }}

),

fact_in_scope as (

    select
          count(*) as row_count
        , coalesce(sum(f.on_hand_qty), 0) as on_hand_qty
    from {{ ref('fact_inventory_snapshot_daily') }} f
    inner join latest l
        on f.snapshot_date = l.snapshot_date
    inner join {{ ref('ref_inventory_status') }} st
        on f.inventory_status_code = st.inventory_status_code
        and st.is_current_row = 1
        and st.include_in_std_metrics_flag
    left anti join made_to_order mto
        on f.product_id = mto.product_id

),

view_totals as (

    select
          count(*) as row_count
        , coalesce(sum(v.on_hand_qty), 0) as on_hand_qty
    from {{ ref('v_current_inventory') }} v

)

select
      'made-to-order item in v_current_inventory' as failure
    , cast(count(*) as decimal(38,6)) as value_found
    , cast(0 as decimal(38,6)) as value_expected
from {{ ref('v_current_inventory') }} v
inner join made_to_order mto
    on v.product_id = mto.product_id
having count(*) > 0

union all

select
      'made-to-order item on the latest day of v_metrics_inventory_daily'
    , cast(count(*) as decimal(38,6))
    , cast(0 as decimal(38,6))
from {{ ref('v_metrics_inventory_daily') }} m
inner join latest l
    on m.snapshot_date = l.snapshot_date
inner join made_to_order mto
    on m.product_id = mto.product_id
having count(*) > 0

union all

select
      'v_current_inventory rows differ from the fact filtered the same way'
    , cast(v.row_count as decimal(38,6))
    , cast(f.row_count as decimal(38,6))
from view_totals v
cross join fact_in_scope f
where v.row_count <> f.row_count

union all

select
      'v_current_inventory on-hand units differ from the fact filtered the same way'
    , cast(v.on_hand_qty as decimal(38,6))
    , cast(f.on_hand_qty as decimal(38,6))
from view_totals v
cross join fact_in_scope f
where v.on_hand_qty <> f.on_hand_qty
