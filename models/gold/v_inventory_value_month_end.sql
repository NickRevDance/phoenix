{{ config(materialized = 'view') }}

{% set next_day_close_from = '2026-02-01' %}  {# I6 point 6: a month ending on or after this date closes on the row dated the 1st of the next month #}
{% set close_capture_cutoff_hour = 6 %}       {# a native close row captured at or after this hour (Chicago) on its date holds intraday movement #}

-- V_INVENTORY_VALUE_MONTH_END (Inventory spec v2.14, Section 5.9; EDW-183 step 1, decision record I6).
-- One row per snapshot row on each month's close date, in the certified scope: company-owned
-- statuses (REF_INVENTORY_STATUS include_in_std_metrics_flag) and stocked items only
-- (REF_STOCKING_POLICY: MADE_TO_ORDER items out on product_id and, for backfill rows that carry
-- no product_id, on the UPCs the item's native rows carry). The scope is the same as
-- V_METRICS_INVENTORY_DAILY's, so on a close date this view holds that view's rows.
-- CLOSE ROW (I6 point 6): through January 2026 a month closes on its month-end row. D365 re-ran
-- those month-ends on 2026-02-11, so each holds the month's own close. From February 2026 D365's
-- Inventory value report and the nightly capture both run just after midnight, so a date holds
-- the prior day's close and a month closes on the row dated the 1st of the next month.
-- month_end_date is the calendar month-end the row stands for, whichever row it comes from, so a
-- consumer relates month_end_date_key to DIM_DATE and needs no date logic of its own.
-- LATE CAPTURE: a native close row captured at or after {{ close_capture_cutoff_hour }} AM Chicago on its date (or later)
-- may hold part of that day's movement as well as the close; is_close_captured_late_flag marks it.
-- It is a capture-time marker, not a measure of the gap to D365: native closes read within
-- about 1 percent of D365's report on 1 AM captures too (spec 5.9). The capture time is the
-- latest etl_insert_datetime on the date's rows, as in V_INVENTORY_MOVEMENT_RECONCILIATION, so a
-- hand-made insert that stamps a new etl_insert_datetime moves it. The cutoff is earlier than
-- that view's noon: the reconciliation needs only the date whose movement a snapshot holds,
-- while a close is clean only if it was taken before the warehouse day starts. Backfill rows are
-- D365's own report output and are never flagged. On 2026-10-26 the flag is set on the August
-- and September 2026 closes: the 2026-09-01 row (captured 6:20 PM) and the 2026-10-01 row
-- (latest capture 2:33 PM; 689 of its rows remain from the 1:11 AM run, spec 2.7).
-- SEAM AND COST BASIS (spec 2.5): closes through July 2026 are backfill rows (legacy
-- f_KPI_InventoryValue, the output of D365's Inventory value report); closes from August 2026 are
-- native rows. moving_avg_cost_amount is D365 moving average on both branches (EDW-180, filled
-- in place 2026-10-22), NULL where D365 carries no positive value. standard_cost_amount is the
-- purchase price on native rows and D365's own value on backfill rows (spec 2.5), so it is not a
-- purchase price trend before the August 2026 close.
-- The month in progress has no row until its close row is captured. A month whose close row is
-- missing has no rows; assert_v_inventory_value_month_end_closes reports it.

with status_scope as (

    select st.inventory_status_code
    from {{ ref('ref_inventory_status') }} st
    where st.is_current_row = 1
      and st.include_in_std_metrics_flag

),

made_to_order as (

    select product_id
    from {{ ref('ref_stocking_policy') }}
    where stocking_policy = 'MADE_TO_ORDER'

),

made_to_order_upc as (

    select distinct f.upc
    from {{ ref('fact_inventory_snapshot_daily') }} f
    inner join made_to_order mto
        on f.product_id = mto.product_id
    where f.upc is not null

),

candidate_dates as (

    -- month-end rows and 1st-of-month rows only; one branch per snapshot date (seam 2026-09-01)
    select
          f.snapshot_date
        , max(case
                when f.record_source_table = {{ inventory_snapshot_branch_label('native') }}
                    then from_utc_timestamp(f.etl_insert_datetime, 'America/Chicago')
              end) as native_capture_datetime_ct
    from {{ ref('fact_inventory_snapshot_daily') }} f
    where f.snapshot_date = last_day(f.snapshot_date)
       or day(f.snapshot_date) = 1
    group by 1

),

close_dates as (

    select
          case
            when day(d.snapshot_date) = 1 then date_sub(d.snapshot_date, 1)
            else d.snapshot_date
          end as month_end_date
        , d.snapshot_date as close_snapshot_date
        , case
            when day(d.snapshot_date) = 1 then 'NEXT_MONTH_FIRST_ROW'
            else 'MONTH_END_ROW'
          end as close_rule
        , case
            when d.native_capture_datetime_ct is null then 0
            when cast(d.native_capture_datetime_ct as date) > d.snapshot_date then 1
            when hour(d.native_capture_datetime_ct) >= {{ close_capture_cutoff_hour }} then 1
            else 0
          end as is_close_captured_late_flag
    from candidate_dates d
    where (d.snapshot_date = last_day(d.snapshot_date) and d.snapshot_date < date'{{ next_day_close_from }}')
       or (day(d.snapshot_date) = 1 and date_sub(d.snapshot_date, 1) >= date'{{ next_day_close_from }}')

),

final as (

    select

    -- Core ID
          f.inventory_snapshot_key
        , cast(date_format(c.month_end_date, 'yyyyMMdd') as int) as month_end_date_key  -- relate to DIM_DATE here
        , c.month_end_date
        , f.snapshot_date_key as close_snapshot_date_key
        , f.snapshot_date     as close_snapshot_date
        , c.close_rule
        , c.is_close_captured_late_flag
        , f.record_source_table  -- seam label (spec 2.5)
        , f.product_key
        , f.product_id
        , f.upc
        , f.warehouse_key
        , f.warehouse_id
        , f.inventory_status_code

    -- Measures
        , f.on_hand_qty
        , f.moving_avg_cost_unit
        , f.moving_avg_cost_amount  -- the inventory value (I6)
        , f.standard_cost_amount    -- purchase price on native rows; D365's value on backfill rows

    from {{ ref('fact_inventory_snapshot_daily') }} f
    inner join close_dates c
        on f.snapshot_date = c.close_snapshot_date
    inner join status_scope st
        on f.inventory_status_code = st.inventory_status_code
    -- EDW-144: stocked items only
    left anti join made_to_order mto
        on f.product_id = mto.product_id
    left anti join made_to_order_upc mtu
        on f.upc = mtu.upc

)

select * from final