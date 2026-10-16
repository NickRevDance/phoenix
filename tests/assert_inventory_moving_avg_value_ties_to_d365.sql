{{ config(severity = 'warn') }}

-- EDW-180: the latest snapshot's inventory value at moving average must stay within 1 percent
-- of D365's own inventory value, summed from the same InventTrans legs the snapshot fact costs
-- from. The allowed gap is physical vs financial timing (registered and picked quantities count
-- in on-hand, not in value) and positions the fact leaves out (non-merchandise items, catalogs,
-- zero positions). On 2026-10-16: $28.25M on the snapshot logic against $28.28M in D365, 0.1
-- percent. Returns one row when outside tolerance.

with snapshot_value as (

    select sum(f.moving_avg_cost_amount) as snapshot_value
    from {{ ref('fact_inventory_snapshot_daily') }} f
    where f.snapshot_date = (select max(snapshot_date) from {{ ref('fact_inventory_snapshot_daily') }})

),

d365_value as (

    select sum(case
                when t.STATUSRECEIPT = 1 or t.STATUSISSUE = 1 then t.COSTAMOUNTPOSTED + t.COSTAMOUNTADJUSTMENT
                when t.STATUSRECEIPT = 2 or t.STATUSISSUE = 2 then t.COSTAMOUNTPHYSICAL
                else 0
           end) as d365_value
    from {{ ref('silver_d365_inventory_trans') }} t
    where t.STATUSRECEIPT in (1, 2)
       or t.STATUSISSUE in (1, 2)

)

select
      s.snapshot_value
    , d.d365_value
    , s.snapshot_value - d.d365_value as difference
from snapshot_value s
cross join d365_value d
where s.snapshot_value is null
   or abs(s.snapshot_value - d.d365_value) > 0.01 * abs(d.d365_value)