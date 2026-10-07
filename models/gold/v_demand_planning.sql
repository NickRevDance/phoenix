{{ config(materialized = 'view') }}

{% set yoy_offset_days = 364 %}

{#-
    comparison_window_days is read from REF_DEMAND_PLANNING_THRESHOLDS when dbt builds the
    view, so the two flag windows can be plain window frames (a frame needs a constant). A
    change to the seed row takes effect on the next build, the same run that reloads the seed.
    assert_v_demand_planning_ties_to_fact fails if the view and the seed ever disagree.
    The value 1 below is only what dbt sees while parsing the project; it never reaches SQL.
-#}
{% if execute %}
    {% set window_query %}
        select cast(parameter_value as int) as comparison_window_days
        from {{ ref('ref_demand_planning_thresholds') }}
        where is_active = 1
          and parameter_name = 'comparison_window_days'
    {% endset %}
    {% set window_rows = run_query(window_query).rows %}
    {% if window_rows | length != 1 or window_rows[0][0] is none or window_rows[0][0] | int < 1 %}
        {{ exceptions.raise_compiler_error("v_demand_planning: expected exactly one active comparison_window_days row of 1 or more in ref_demand_planning_thresholds, found " ~ (window_rows | length) ~ " row(s).") }}
    {% endif %}
    {% set comparison_window_days = window_rows[0][0] | int %}
{% else %}
    {% set comparison_window_days = 1 %}
{% endif %}

{#- The last day a combination's year-ago window can still hold its latest order. -#}
{% set spine_days_after_last_order = yoy_offset_days + comparison_window_days - 1 %}

-- V_DEMAND_PLANNING (EDW-61; FACT_ORDER_LINE spec Section 9.2; Phase 2 Orders and Sales
-- decision O9, ratified). The certified demand view: ordered demand net of cancellations.
-- Grain: one row per order_date_key + product_key + sales_channel_key + warehouse_key.
-- Demand basis: FACT_ORDER_LINE ordered_qty by order date (the demand signal, not shipments
-- and not invoices). V_METRICS_INVENTORY_DAILY uses invoiced demand; the two are different
-- numbers on purpose.
-- Net of cancellations: the cancellation state comes from FACT_ORDERS_RETURNS on the shared
-- sales line key. A line whose status is Cancelled counts as zero demand whether or not it
-- carries a cancelled quantity (most do not). Any other line counts ordered_qty less
-- cancelled_qty, never below zero. Cancellation is current state, so a later cancel restates
-- the days it touches.
-- Dense days: a product + channel + warehouse combination has a row for every calendar day
-- from its first order to {{ spine_days_after_last_order }} days after its latest order (never past the latest order date
-- in the fact), including days with no orders. {{ spine_days_after_last_order }} is the year-over-year offset plus the
-- comparison window less one: the last day the combination's year-ago window can still hold
-- its latest order, so a combination that sold a year ago and has not sold since keeps its
-- row and shows as a year-over-year decline. Every row after that day would be zero on
-- every measure.
-- Latest day: the latest order date in the fact is a part day at load time. It is kept so
-- the daily measures tie to the fact and is marked is_partial_day_flag. Read "as of now"
-- from the latest row where is_partial_day_flag is false.
-- Rolling windows: demand_7d, demand_30d and demand_90d are calendar-day sums of demand_qty
-- ending on the row's day.
-- Flags: both flags use one window length, comparison_window_days ({{ comparison_window_days }} in this build), read
-- from REF_DEMAND_PLANNING_THRESHOLDS when dbt builds the view. The other three thresholds
-- are read from the same table when the view is queried (the active row per parameter), so
-- a threshold change applies to every date in the view, not only to dates after the change.
-- demand_trend_flag compares that window with the one before it; demand_yoy_flag compares it
-- with the same window {{ yoy_offset_days }} days earlier (52 weeks, so weekdays line up). Insufficient when
-- the two windows together hold fewer units than insufficient_units_60d, or when the earlier
-- window starts before the fact's first order date. Increasing at or above
-- trend_increasing_pct, Declining at or below trend_declining_pct, Stable between. The three
-- window quantities the flags compare are carried beside them. No threshold is typed into
-- this model: each one changes with a seed row.
-- Early history: the fact holds fewer than 100 order lines before June 2023 and reaches
-- normal volume in early July 2023, but the Insufficient rule only knows the fact's first
-- order date (January 15 2023). demand_trend_flag before about September 2023 and
-- demand_yoy_flag before about August 2024 therefore compare against months the fact does
-- not fully hold. Current dates are not affected.
-- Units only: the view carries no amounts. net_line_amount on the fact is as ordered (not
-- reduced for cancellations) and in the line's transaction currency, so it does not sit on
-- the same basis as demand_qty. A USD demand amount can be added once the fact carries one.
-- Not in the view: order lines with no order date (their order header is gone at the source)
-- have no day to land on. They are the only rows of the fact left out.
-- Dimension attributes: the latest version of each dimension row (version_number = 1).

with thresholds as (

    select
          max(case when parameter_name = 'trend_increasing_pct' then parameter_value end)          as trend_increasing_pct
        , max(case when parameter_name = 'trend_declining_pct' then parameter_value end)           as trend_declining_pct
        , max(case when parameter_name = 'insufficient_units_60d' then parameter_value end)        as insufficient_units
    from {{ ref('ref_demand_planning_thresholds') }}
    where is_active = 1

),

order_line as (

    select

          o.order_date
        , o.product_key
        , o.sales_channel_key
        , o.warehouse_key
        , o.ordered_qty
        , case when r.order_line_status = 'Cancelled' then o.ordered_qty
               else greatest(least(coalesce(r.cancelled_qty, 0), o.ordered_qty), 0)
          end                                                         as cancelled_qty

    from {{ ref('fact_order_line') }} o

    -- Same sales line on both facts: each key is xxhash64(SalesLine REC, 'D365').
    left join {{ ref('fact_orders_returns') }} r
        on o.order_line_key = r.orders_returns_key

    where o.order_date is not null

),

daily as (

    select

          l.order_date
        , l.product_key
        , l.sales_channel_key
        , l.warehouse_key
        , count(*)                                                    as order_line_count
        , sum(l.ordered_qty)                                          as ordered_qty
        , sum(l.cancelled_qty)                                        as cancelled_qty
        , sum(l.ordered_qty - l.cancelled_qty)                        as demand_qty

    from order_line l

    group by
          l.order_date
        , l.product_key
        , l.sales_channel_key
        , l.warehouse_key

),

history as (

    select
          min(order_date) as history_start_date
        , max(order_date) as as_of_date
    from daily

),

combination as (

    select
          product_key
        , sales_channel_key
        , warehouse_key
        , min(order_date) as first_order_date
        , max(order_date) as last_order_date
    from daily
    group by
          product_key
        , sales_channel_key
        , warehouse_key

),

spine as (

    select
          c.product_key
        , c.sales_channel_key
        , c.warehouse_key
        , explode(sequence(
              c.first_order_date
            , least(date_add(c.last_order_date, {{ spine_days_after_last_order }}), h.as_of_date)
            , interval 1 day
          ))                                                          as order_date
    from combination c
    cross join history h

),

dense as (

    select

          s.order_date
        , s.product_key
        , s.sales_channel_key
        , s.warehouse_key
        , coalesce(d.order_line_count, 0)                             as order_line_count
        , coalesce(d.ordered_qty, 0)                                  as ordered_qty
        , coalesce(d.cancelled_qty, 0)                                as cancelled_qty
        , coalesce(d.demand_qty, 0)                                   as demand_qty

    from spine s

    left join daily d
        on s.order_date = d.order_date
        and s.product_key = d.product_key
        and s.sales_channel_key = d.sales_channel_key
        and s.warehouse_key <=> d.warehouse_key

),

-- One row per calendar day per combination, so a frame of n rows is a window of n days. A
-- frame that reaches back past the combination's first order has fewer rows, or none, and
-- the days it is missing are days with no demand.
windowed as (

    select

          x.*
        , sum(x.demand_qty) over (
              partition by x.product_key, x.sales_channel_key, x.warehouse_key
              order by x.order_date
              rows between 6 preceding and current row
          )                                                           as demand_7d
        , sum(x.demand_qty) over (
              partition by x.product_key, x.sales_channel_key, x.warehouse_key
              order by x.order_date
              rows between 29 preceding and current row
          )                                                           as demand_30d
        , sum(x.demand_qty) over (
              partition by x.product_key, x.sales_channel_key, x.warehouse_key
              order by x.order_date
              rows between 89 preceding and current row
          )                                                           as demand_90d
        , sum(x.demand_qty) over (
              partition by x.product_key, x.sales_channel_key, x.warehouse_key
              order by x.order_date
              rows between {{ comparison_window_days - 1 }} preceding and current row
          )                                                           as demand_window_qty
        , coalesce(sum(x.demand_qty) over (
              partition by x.product_key, x.sales_channel_key, x.warehouse_key
              order by x.order_date
              rows between {{ 2 * comparison_window_days - 1 }} preceding and {{ comparison_window_days }} preceding
          ), 0)                                                       as demand_prior_window_qty
        , coalesce(sum(x.demand_qty) over (
              partition by x.product_key, x.sales_channel_key, x.warehouse_key
              order by x.order_date
              rows between {{ yoy_offset_days + comparison_window_days - 1 }} preceding and {{ yoy_offset_days }} preceding
          ), 0)                                                       as demand_ly_window_qty

    from dense x

),

date_dim as (

    select
          date_key
        , fiscal_year
        , fiscal_quarter
        , fiscal_month
        , fiscal_year_week
    from {{ ref('dim_date') }}

),

product as (

    select
          product_key
        , product_id
        , style_number
        , style_name
        , summary_class
        , product_group
        , division_season
        , gender
    from {{ ref('dim_product') }}
    where version_number = 1

),

channel as (

    select
          sales_channel_key
        , channel_code
        , channel_name
        , channel_type
    from {{ ref('dim_sales_channel') }}

),

warehouse as (

    select
          warehouse_key
        , warehouse_id
        , warehouse_name
    from {{ ref('dim_warehouse') }}
    where version_number = 1

)

select

    -- Grain
      cast(date_format(c.order_date, 'yyyyMMdd') as int)             as order_date_key
    , c.product_key
    , c.sales_channel_key
    , c.warehouse_key

    -- Date attributes
    , c.order_date
    , case when c.order_date = h.as_of_date then true else false end as is_partial_day_flag
    , dt.fiscal_year
    , dt.fiscal_quarter
    , dt.fiscal_month
    , dt.fiscal_year_week

    -- Product attributes
    , pr.product_id
    , pr.style_number
    , pr.style_name
    , pr.summary_class
    , pr.product_group
    , pr.division_season
    , pr.gender

    -- Sales channel attributes
    , ch.channel_code
    , ch.channel_name
    , ch.channel_type

    -- Warehouse attributes
    , wh.warehouse_id
    , wh.warehouse_name

    -- Demand on the day
    , c.order_line_count
    , {{ amount('c.ordered_qty') }}                                   as ordered_qty
    , {{ amount('c.cancelled_qty') }}                                 as cancelled_qty
    , {{ amount('c.demand_qty') }}                                    as demand_qty

    -- Rolling demand, ending on the day
    , {{ amount('c.demand_7d') }}                                     as demand_7d
    , {{ amount('c.demand_30d') }}                                    as demand_30d
    , {{ amount('c.demand_90d') }}                                    as demand_90d

    -- What the flags compare
    , cast({{ comparison_window_days }} as int)                                            as comparison_window_days
    , {{ amount('c.demand_window_qty') }}                             as demand_window_qty
    , {{ amount('c.demand_prior_window_qty') }}                       as demand_prior_window_qty
    , {{ amount('c.demand_ly_window_qty') }}                          as demand_ly_window_qty

    -- Flags
    , case
        when t.trend_increasing_pct is null or t.trend_declining_pct is null
          or t.insufficient_units is null
            then cast(null as string)
        when date_sub(c.order_date, {{ 2 * comparison_window_days - 1 }}) < h.history_start_date
            then 'Insufficient'
        when c.demand_window_qty + c.demand_prior_window_qty <= 0
          or c.demand_window_qty + c.demand_prior_window_qty < t.insufficient_units
            then 'Insufficient'
        when c.demand_window_qty >= c.demand_prior_window_qty * (1 + t.trend_increasing_pct)
            then 'Increasing'
        when c.demand_window_qty <= c.demand_prior_window_qty * (1 + t.trend_declining_pct)
            then 'Declining'
        else 'Stable'
      end                                                             as demand_trend_flag
    , case
        when t.trend_increasing_pct is null or t.trend_declining_pct is null
          or t.insufficient_units is null
            then cast(null as string)
        when date_sub(c.order_date, {{ yoy_offset_days + comparison_window_days - 1 }}) < h.history_start_date
            then 'Insufficient'
        when c.demand_window_qty + c.demand_ly_window_qty <= 0
          or c.demand_window_qty + c.demand_ly_window_qty < t.insufficient_units
            then 'Insufficient'
        when c.demand_window_qty >= c.demand_ly_window_qty * (1 + t.trend_increasing_pct)
            then 'Increasing'
        when c.demand_window_qty <= c.demand_ly_window_qty * (1 + t.trend_declining_pct)
            then 'Declining'
        else 'Stable'
      end                                                             as demand_yoy_flag

from windowed c

cross join history h

cross join thresholds t

left join date_dim dt
    on cast(date_format(c.order_date, 'yyyyMMdd') as int) = dt.date_key

left join product pr
    on c.product_key = pr.product_key

left join channel ch
    on c.sales_channel_key = ch.sales_channel_key

left join warehouse wh
    on c.warehouse_key = wh.warehouse_key