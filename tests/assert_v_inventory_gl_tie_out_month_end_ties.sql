{{ config(severity = 'warn') }}

-- EDW-183 step 2 (Inventory spec 5.10, decision record I6 point 9): every month-end close ties
-- gold to the general ledger, bucket by bucket and in total, or the difference is explained by
-- a reconciling line. Returns each close and bucket left at VARIANCE, with its figures, so a new
-- month that does not tie shows on the nightly run.

select
      month_end_date
    , gl_bucket
    , gl_balance_amount
    , gl_manual_journal_in_month_amount
    , gl_posted_after_close_amount
    , d365_value_amount
    , gold_value_amount
    , variance_gold_to_gl_amount
    , variance_d365_to_gl_at_close_amount
from {{ ref('v_inventory_gl_tie_out_month_end') }}
where tie_status = 'VARIANCE'