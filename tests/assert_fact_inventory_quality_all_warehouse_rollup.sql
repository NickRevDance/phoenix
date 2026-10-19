-- Every code_color/day with a warehouse row has an all-warehouse row, and the all-warehouse quantities equal the sum of its warehouse rows.

with by_warehouse as (

    select
          q.snapshot_date
        , q.code_color
        , sum(q.total_on_hand_qty) as on_hand_qty
        , sum(q.total_available_qty) as available_qty

    from {{ ref('fact_inventory_quality_code_color_daily') }} q
    where q.warehouse_key is not null
    group by q.snapshot_date, q.code_color

),

all_warehouse as (

    select
          q.snapshot_date
        , q.code_color
        , q.total_on_hand_qty as on_hand_qty
        , q.total_available_qty as available_qty

    from {{ ref('fact_inventory_quality_code_color_daily') }} q
    where q.warehouse_key is null

)

select
      bw.snapshot_date
    , bw.code_color
    , bw.on_hand_qty as warehouse_on_hand_qty
    , aw.on_hand_qty as all_warehouse_on_hand_qty

from by_warehouse bw
left join all_warehouse aw
    on bw.snapshot_date = aw.snapshot_date
   and bw.code_color = aw.code_color
where aw.code_color is null
   or abs(bw.on_hand_qty - aw.on_hand_qty) > 0.001
   or abs(bw.available_qty - aw.available_qty) > 0.001
