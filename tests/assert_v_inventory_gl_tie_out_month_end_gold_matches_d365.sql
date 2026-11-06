{{ config(severity = 'warn') }}

-- EDW-188 (Inventory spec 5.10): at every month-end close gold's value equals D365's Inventory value
-- report, bucket by bucket and in total, to rounding. Gold is filled from D365's report and, from
-- EDW-188, carries D365's own amount on lines with no positive value or quantity, so any gap above a
-- dollar is a fill, a capture or a rule that has drifted. A close at LATE_CAPTURE (an afternoon
-- capture, August 2026) is left out: its gap is the day's movement and is explained there. A close
-- whose D365 run is not in silver yet has a NULL variance and is not judged until it lands; the
-- morning after a close captured before the job timing moved, the row reads the capture's own gap
-- until the morning correction (edw187_snapshot_correction.sql) has run. Returns each close and
-- bucket more than a dollar apart.

select
      month_end_date
    , gl_bucket
    , close_snapshot_date
    , d365_value_amount
    , gold_value_amount
    , variance_gold_to_d365_amount
    , tie_status
from {{ ref('v_inventory_gl_tie_out_month_end') }}
where is_tied_to_gold_flag
  and tie_status <> 'LATE_CAPTURE'
  and abs(variance_gold_to_d365_amount) > 1