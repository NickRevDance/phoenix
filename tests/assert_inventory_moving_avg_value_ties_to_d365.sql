{{ config(severity = 'warn') }}

-- EDW-180: the latest snapshot's inventory value at moving average must stay within 1 percent
-- of D365's own inventory value, summed from the same InventTrans legs the snapshot fact costs
-- from. EDW-187: the fact now values D365's own valued quantity on case-insensitive variants,
-- so the gap left is what the fact leaves out by design: non-merchandise items and, until
-- EDW-188, groups with no positive value (the NULL rule). On the 2026-11-02 state: $29,333,757.27
-- on the changed logic against $29,333,621.27 in D365, +$136.00. EDW-188: those groups carry their
-- own InventTrans value, so only the non-merchandise items (zero cost) remain outside. Before
-- EDW-187 the gap also carried registered and picked quantities and exact-case cost groups
-- ($28.25M against $28.28M on 2026-10-16). The 1 percent tolerance is unchanged. Returns one row
-- when outside tolerance.

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
    where (t.STATUSRECEIPT in (1, 2) or t.STATUSISSUE in (1, 2))
      and coalesce(t.is_deleted, 0) = 0  -- EDW-177

)

select
      s.snapshot_value
    , d.d365_value
    , s.snapshot_value - d.d365_value as difference
from snapshot_value s
cross join d365_value d
where s.snapshot_value is null
   or abs(s.snapshot_value - d.d365_value) > 0.01 * abs(d.d365_value)