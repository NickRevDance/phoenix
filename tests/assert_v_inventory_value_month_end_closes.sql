{{ config(severity = 'warn') }}

-- EDW-183 (Inventory spec 5.9, decision record I6 point 6): every month has exactly one close
-- row, from the month of the fact's first snapshot date to the latest completed month. Returns a
-- row for each failure:
--   1. a month read from more than one snapshot date;
--   2. a month missing between the first snapshot month and the latest close (a missed capture
--      on a close date leaves that month out of the view, D012);
--   3. the latest completed month has no close yet (the 1st's capture did not run), judged
--      against the latest snapshot date on the fact.

with closes as (

    select
          month_end_date
        , count(distinct close_snapshot_date) as close_dates
    from {{ ref('v_inventory_value_month_end') }}
    group by 1

),

fact_bounds as (

    select
          last_day(min(snapshot_date))              as first_month_end
        , last_day(add_months(max(snapshot_date), -1)) as latest_completed_month_end
    from {{ ref('fact_inventory_snapshot_daily') }}

),

expected_months as (

    select last_day(add_months(b.first_month_end, s.n)) as month_end_date
    from fact_bounds b
    lateral view posexplode(sequence(0, cast(months_between(b.latest_completed_month_end, b.first_month_end) as int))) s as n, v

)

select
      'month read from more than one snapshot date' as failure
    , c.month_end_date
from closes c
where c.close_dates > 1

union all

select
      case
        when e.month_end_date = b.latest_completed_month_end then 'latest completed month has no close'
        else 'month missing between the first snapshot month and the latest close'
      end
    , e.month_end_date
from expected_months e
cross join fact_bounds b
left anti join closes c
    on c.month_end_date = e.month_end_date