{{ config(materialized = 'view') }}

-- V_INVENTORY_MOVEMENT_RECONCILIATION (spec 5.7, Phase 1, required for EDW-14
-- sign-off). Certifies that FACT_INVENTORY_MOVEMENT explains
-- FACT_INVENTORY_SNAPSHOT_DAILY: delta reconciliation per product x warehouse
-- x inventory_status_code between consecutive native-window snapshot dates.
-- 0-unit tolerance (EDW-14 decision). Native window only -- the backfill
-- branch has no movement counterpart (spec 2.5). Scope is ALL statuses and
-- warehouses on purpose; include_in_std_metrics_flag does NOT apply here --
-- this is physical accounting, not a certified metric view.
-- Grain note: spec's "activity on either side" is read here as either the
-- snapshot or the movement side, not snapshot alone -- a movement-only combo
-- with no snapshot footprint at either end is exactly the kind of gap this
-- view exists to surface, so it's included (as a non-zero variance) rather
-- than silently dropped.
-- DQ flag: as of 2026-09-01, ~10% of native snapshot rows carry a null
-- product_key (no dim_product match) and a meaningful share carry a null
-- inventory_status_code (a stale pre-fix merge, not a live join miss --
-- silver_byod_inventory_sum/_dim join clean at the source). Both are
-- coalesced to a single bucket ('UNMATCHED_PRODUCT' / 'UNKNOWN') per
-- warehouse so this view reconciles in total rather than fanning out on the
-- missing keys; this collapses distinct unmatched SKUs together and is a
-- real precision loss, not a fix for the underlying gaps

with native_snapshot as (

    select

          snapshot_date_key
        , snapshot_date
        , product_key
        , product_id
        , warehouse_key
        , warehouse_id
        , inventory_status_code
        , on_hand_qty

    from {{ ref('fact_inventory_snapshot_daily') }}
    where record_source_table = 'silver_byod_inventory_sum + silver_byod_inventory_dim'

),

snapshot_agg as (

    -- Collapses to one row per date x key before any join, both to apply the
    -- UNKNOWN-status default consistently and to avoid a null-key join
    -- fanning out across otherwise-distinct unmatched rows (GROUP BY treats
    -- NULL as one group; a join predicate does not).

    select

          snapshot_date_key
        , snapshot_date
        , coalesce(product_key, 'UNMATCHED_PRODUCT') as product_key
        , max(product_id)                        as product_id
        , warehouse_key
        , max(warehouse_id)                      as warehouse_id
        , coalesce(inventory_status_code, 'UNKNOWN') as inventory_status_code
        , sum(on_hand_qty)                       as on_hand_qty

    from native_snapshot
    group by 1, 2, 3, 5, 7

),

distinct_dates as (

    select distinct snapshot_date_key, snapshot_date
    from snapshot_agg

),

snapshot_dates as (

    -- lag() must run over one row per date (distinct_dates), not over every
    -- detail row -- otherwise ties within a date make most rows pair with
    -- themselves instead of with the prior date.

    select

          snapshot_date_key
        , snapshot_date
        , lag(snapshot_date_key) over (order by snapshot_date) as period_start_date_key
        , lag(snapshot_date)     over (order by snapshot_date) as period_start_date

    from distinct_dates

),

date_pairs as (

    -- Pairs actual adjacent native snapshot dates rather than assuming a daily
    -- cadence, so sparse history reconciles over its real gaps.

    select

          period_start_date_key
        , period_start_date
        , snapshot_date_key as period_end_date_key
        , snapshot_date     as period_end_date

    from snapshot_dates
    where period_start_date_key is not null  -- the earliest native date has no prior pair

),

snapshot_start as (

    select

          dp.period_start_date_key
        , dp.period_end_date_key
        , s.product_key
        , s.product_id
        , s.warehouse_key
        , s.warehouse_id
        , s.inventory_status_code
        , s.on_hand_qty as snapshot_qty_start

    from date_pairs dp
    inner join snapshot_agg s
        on s.snapshot_date_key = dp.period_start_date_key

),

snapshot_end as (

    select

          dp.period_start_date_key
        , dp.period_end_date_key
        , s.product_key
        , s.product_id
        , s.warehouse_key
        , s.warehouse_id
        , s.inventory_status_code
        , s.on_hand_qty as snapshot_qty_end

    from date_pairs dp
    inner join snapshot_agg s
        on s.snapshot_date_key = dp.period_end_date_key

),

snapshot_combined as (

    -- One row per date on each side after snapshot_agg's pre-aggregation, so
    -- this join can't fan out even on the 'UNMATCHED_PRODUCT'/'UNKNOWN'
    -- sentinel buckets.

    select

          coalesce(s0.period_start_date_key, s1.period_start_date_key) as period_start_date_key
        , coalesce(s0.period_end_date_key, s1.period_end_date_key)     as period_end_date_key
        , coalesce(s0.product_key, s1.product_key)                     as product_key
        , coalesce(s0.product_id, s1.product_id)                       as product_id
        , coalesce(s0.warehouse_key, s1.warehouse_key)                 as warehouse_key
        , coalesce(s0.warehouse_id, s1.warehouse_id)                   as warehouse_id
        , coalesce(s0.inventory_status_code, s1.inventory_status_code) as inventory_status_code
        , coalesce(s0.snapshot_qty_start, 0)                           as snapshot_qty_start
        , coalesce(s1.snapshot_qty_end, 0)                             as snapshot_qty_end

    from snapshot_start s0
    full outer join snapshot_end s1
        on  s0.period_start_date_key  = s1.period_start_date_key
        and s0.product_key            = s1.product_key
        and s0.warehouse_key          = s1.warehouse_key
        and s0.inventory_status_code  = s1.inventory_status_code

),

movement_net as (

    -- (s0, s1]: exclusive of period start, inclusive of period end -- matches
    -- spec 5.7's delta method exactly. Same 'UNMATCHED_PRODUCT'/'UNKNOWN'
    -- sentinel keying as snapshot_agg so the two sides can join without a
    -- null mismatch.

    select

          dp.period_start_date_key
        , dp.period_end_date_key
        , coalesce(m.product_key, 'UNMATCHED_PRODUCT') as product_key
        , max(m.product_id)                         as product_id
        , m.warehouse_key
        , max(m.warehouse_id)                        as warehouse_id
        , coalesce(m.inventory_status_code, 'UNKNOWN') as inventory_status_code
        , sum(m.quantity_change)                                                                       as movement_net_qty
        , sum(case when m.movement_type = 'RECEIPT'                        then m.quantity_change end)  as receipt_net
        , sum(case when m.movement_type = 'SHIPMENT'                       then m.quantity_change end)  as shipment_net
        , sum(case when m.movement_type = 'RETURN'                         then m.quantity_change end)  as return_net
        , sum(case when m.movement_type in ('TRANSFER_IN', 'TRANSFER_OUT') then m.quantity_change end)  as transfer_net
        , sum(case when m.movement_type = 'STATUS_CHANGE'                  then m.quantity_change end)  as status_change_net
        , sum(case when m.movement_type = 'ADJUSTMENT'                     then m.quantity_change end)  as adjustment_net
        , sum(case when m.movement_type = 'UNKNOWN'                        then m.quantity_change end)  as unknown_net

    from date_pairs dp
    inner join {{ ref('fact_inventory_movement') }} m
        on  m.movement_date_key >  dp.period_start_date_key
        and m.movement_date_key <= dp.period_end_date_key

    group by 1, 2, 3, 5, 7

),

combined as (

    select

          coalesce(sc.period_start_date_key, mv.period_start_date_key) as period_start_date_key
        , coalesce(sc.period_end_date_key, mv.period_end_date_key)     as period_end_date_key
        , coalesce(sc.product_key, mv.product_key)                     as product_key
        , coalesce(sc.product_id, mv.product_id)                       as product_id
        , coalesce(sc.warehouse_key, mv.warehouse_key)                 as warehouse_key
        , coalesce(sc.warehouse_id, mv.warehouse_id)                   as warehouse_id
        , coalesce(sc.inventory_status_code, mv.inventory_status_code) as inventory_status_code
        , coalesce(sc.snapshot_qty_start, 0)                           as snapshot_qty_start
        , coalesce(sc.snapshot_qty_end, 0)                             as snapshot_qty_end
        , coalesce(mv.movement_net_qty, 0)                             as movement_net_qty
        , coalesce(mv.receipt_net, 0)                                  as receipt_net
        , coalesce(mv.shipment_net, 0)                                 as shipment_net
        , coalesce(mv.return_net, 0)                                   as return_net
        , coalesce(mv.transfer_net, 0)                                 as transfer_net
        , coalesce(mv.status_change_net, 0)                            as status_change_net
        , coalesce(mv.adjustment_net, 0)                               as adjustment_net
        , coalesce(mv.unknown_net, 0)                                  as unknown_net

    from snapshot_combined sc
    full outer join movement_net mv
        on  sc.period_start_date_key = mv.period_start_date_key
        and sc.period_end_date_key   = mv.period_end_date_key
        and sc.product_key           = mv.product_key
        and sc.warehouse_key         = mv.warehouse_key
        and sc.inventory_status_code = mv.inventory_status_code

),

final as (

    select

          c.period_start_date_key
        , c.period_end_date_key
        , nullif(c.product_key, 'UNMATCHED_PRODUCT') as product_key  -- sentinel marks the "no dim_product match" bucket, see header note
        , c.product_id
        , c.warehouse_key
        , c.warehouse_id
        , c.inventory_status_code
        , c.snapshot_qty_start
        , c.snapshot_qty_end
        , c.snapshot_qty_end - c.snapshot_qty_start as snapshot_delta
        , c.movement_net_qty
        , c.receipt_net
        , c.shipment_net
        , c.return_net
        , c.transfer_net
        , c.status_change_net
        , c.adjustment_net
        , c.unknown_net
        , c.movement_net_qty - (c.snapshot_qty_end - c.snapshot_qty_start) as variance_qty
        , case
            when c.movement_net_qty - (c.snapshot_qty_end - c.snapshot_qty_start) = 0 then 'MATCHED'
            else 'VARIANCE'
          end as reconciliation_status

    from combined c

)

select * from final
