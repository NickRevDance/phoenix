-- EDW-61: V_DEMAND_PLANNING holds every FACT_ORDER_LINE row that has an order date, so its
-- daily measures summed over the view equal the same sums over the fact. Also checks that
-- demand never leaves the range 0 to ordered_qty, that every row carries both flags (a NULL
-- flag means a threshold has no active row in REF_DEMAND_PLANNING_THRESHOLDS), and that the
-- window length built into the view is still the active comparison_window_days row (the view
-- reads it when dbt builds it, so the two differ only if the seed moved without a rebuild).
-- Returns a row for each check that fails. The view is read once.

with fact_totals as (

    select
          cast(count(*) as decimal(38,6))                             as order_line_count
        , cast(coalesce(sum(ordered_qty), 0) as decimal(38,6))        as ordered_qty
    from {{ ref('fact_order_line') }}
    where order_date is not null

),

seed_window as (

    select
        cast(coalesce(max(case when parameter_name = 'comparison_window_days' then parameter_value end), -1) as decimal(38,6))
                                                                      as comparison_window_days
    from {{ ref('ref_demand_planning_thresholds') }}
    where is_active = 1

),

view_totals as (

    select
          cast(coalesce(sum(order_line_count), 0) as decimal(38,6))   as order_line_count
        , cast(coalesce(sum(ordered_qty), 0) as decimal(38,6))        as ordered_qty
        , cast(coalesce(sum(case when demand_qty < 0 or demand_qty > ordered_qty then 1 else 0 end), 0) as decimal(38,6))
                                                                      as demand_out_of_range_rows
        , cast(coalesce(sum(case when demand_trend_flag is null or demand_yoy_flag is null then 1 else 0 end), 0) as decimal(38,6))
                                                                      as null_flag_rows
        , cast(coalesce(max(comparison_window_days), 0) as decimal(38,6))
                                                                      as comparison_window_days
    from {{ ref('v_demand_planning') }}

),

checks as (

    select
        stack(
              5
            , 'order_line_count differs from the fact', v.order_line_count, f.order_line_count
            , 'ordered_qty differs from the fact', v.ordered_qty, f.ordered_qty
            , 'rows with demand_qty outside 0 to ordered_qty', v.demand_out_of_range_rows, cast(0 as decimal(38,6))
            , 'rows with a NULL demand flag', v.null_flag_rows, cast(0 as decimal(38,6))
            , 'comparison_window_days in the view differs from the active row in ref_demand_planning_thresholds', v.comparison_window_days, s.comparison_window_days
        ) as (failure, value_found, value_expected)
    from view_totals v
    cross join fact_totals f
    cross join seed_window s

)

select
      failure
    , value_found
    , value_expected
from checks
where value_found <> value_expected