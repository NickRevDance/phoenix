-- EDW-61 acceptance: the rolling windows are validated against a plain calculation. For the
-- latest complete day, every window of every combination is recomputed as a sum of the
-- view's own daily demand_qty over the calendar days it should cover: demand_7d, demand_30d
-- and demand_90d over the trailing 7, 30 and 90 days; demand_window_qty over the trailing
-- comparison_window_days; demand_prior_window_qty over the window before that; and
-- demand_ly_window_qty over the same window 364 days earlier. A difference means the day
-- spine has a gap or a window frame is wrong. Returns a row for each measure with the number
-- of combinations that differ. The view is read once.

with latest_complete_day as (

    select date_sub(max(order_date), 1) as as_of_date
    from {{ ref('fact_order_line') }}

),

recent as (

    select
          v.product_key
        , v.sales_channel_key
        , v.warehouse_key
        , v.order_date
        , v.demand_qty
        , v.demand_7d
        , v.demand_30d
        , v.demand_90d
        , v.demand_window_qty
        , v.demand_prior_window_qty
        , v.demand_ly_window_qty
        , v.comparison_window_days
        , d.as_of_date
    from {{ ref('v_demand_planning') }} v
    cross join latest_complete_day d
    -- far enough back for the longest window checked
    where v.order_date > date_sub(d.as_of_date, greatest(364 + v.comparison_window_days, 2 * v.comparison_window_days, 90))
      and v.order_date <= d.as_of_date

),

recomputed as (

    select
          product_key
        , sales_channel_key
        , warehouse_key
        , max(case when order_date = as_of_date then demand_7d end)   as demand_7d
        , max(case when order_date = as_of_date then demand_30d end)  as demand_30d
        , max(case when order_date = as_of_date then demand_90d end)  as demand_90d
        , max(case when order_date = as_of_date then demand_window_qty end)
                                                                      as demand_window_qty
        , max(case when order_date = as_of_date then demand_prior_window_qty end)
                                                                      as demand_prior_window_qty
        , max(case when order_date = as_of_date then demand_ly_window_qty end)
                                                                      as demand_ly_window_qty
        , sum(case when order_date > date_sub(as_of_date, 7) then demand_qty else 0 end)
                                                                      as plain_7d
        , sum(case when order_date > date_sub(as_of_date, 30) then demand_qty else 0 end)
                                                                      as plain_30d
        , sum(case when order_date > date_sub(as_of_date, 90) then demand_qty else 0 end)
                                                                      as plain_90d
        , sum(case when order_date > date_sub(as_of_date, comparison_window_days) then demand_qty else 0 end)
                                                                      as plain_window
        , sum(case when order_date > date_sub(as_of_date, 2 * comparison_window_days)
                    and order_date <= date_sub(as_of_date, comparison_window_days) then demand_qty else 0 end)
                                                                      as plain_prior_window
        , sum(case when order_date > date_sub(as_of_date, 364 + comparison_window_days)
                    and order_date <= date_sub(as_of_date, 364) then demand_qty else 0 end)
                                                                      as plain_ly_window
    from recent
    group by
          product_key
        , sales_channel_key
        , warehouse_key
    -- only combinations that have a row on the day being checked
    having max(case when order_date = as_of_date then 1 else 0 end) = 1

),

differences as (

    select
          cast(coalesce(sum(case when demand_7d <> plain_7d then 1 else 0 end), 0) as decimal(38,6))   as diff_7d
        , cast(coalesce(sum(case when demand_30d <> plain_30d then 1 else 0 end), 0) as decimal(38,6)) as diff_30d
        , cast(coalesce(sum(case when demand_90d <> plain_90d then 1 else 0 end), 0) as decimal(38,6)) as diff_90d
        , cast(coalesce(sum(case when demand_window_qty <> plain_window then 1 else 0 end), 0) as decimal(38,6))
                                                                                                         as diff_window
        , cast(coalesce(sum(case when demand_prior_window_qty <> plain_prior_window then 1 else 0 end), 0) as decimal(38,6))
                                                                                                         as diff_prior_window
        , cast(coalesce(sum(case when demand_ly_window_qty <> plain_ly_window then 1 else 0 end), 0) as decimal(38,6))
                                                                                                         as diff_ly_window
        , cast(count(*) as decimal(38,6))                                                                as combinations_checked
    from recomputed

),

checks as (

    select
        stack(
              7
            , 'combinations where demand_7d differs from the plain sum', d.diff_7d, cast(0 as decimal(38,6))
            , 'combinations where demand_30d differs from the plain sum', d.diff_30d, cast(0 as decimal(38,6))
            , 'combinations where demand_90d differs from the plain sum', d.diff_90d, cast(0 as decimal(38,6))
            , 'combinations where demand_window_qty differs from the plain sum', d.diff_window, cast(0 as decimal(38,6))
            , 'combinations where demand_prior_window_qty differs from the plain sum', d.diff_prior_window, cast(0 as decimal(38,6))
            , 'combinations where demand_ly_window_qty differs from the plain sum', d.diff_ly_window, cast(0 as decimal(38,6))
            , 'no combination has a row on the latest complete day', case when d.combinations_checked = 0 then cast(1 as decimal(38,6)) else cast(0 as decimal(38,6)) end, cast(0 as decimal(38,6))
        ) as (failure, value_found, value_expected)
    from differences d

)

select
      failure
    , value_found
    , value_expected
from checks
where value_found <> value_expected