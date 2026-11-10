{{ config(materialized = 'view') }}

-- Current version of each PO line (is_current_row = 1: latest version with an open end), so a line deleted in D365 drops out.
-- Lateness is computed here against today, never stored on the fact or hashed.

select
      fpo.* except
        (
              effective_start_datetime
            , effective_end_datetime
            , is_current_row
            , version_number
            , etl_update_datetime
            , row_hash
        )
    , case
        when fpo.open_qty > 0 and fpo.is_closed_flag = 0
         and current_date() > coalesce(fpo.confirmed_receipt_date, fpo.expected_receipt_date)
            then 1 else 0
      end                                                                     as is_late_flag
    , case
        when fpo.open_qty > 0 and fpo.is_closed_flag = 0
         and current_date() > coalesce(fpo.confirmed_receipt_date, fpo.expected_receipt_date)
            then datediff(current_date(), coalesce(fpo.confirmed_receipt_date, fpo.expected_receipt_date))
      end                                                                     as days_late_to_date
from {{ ref('fact_purchase_order') }} fpo
where fpo.is_current_row = 1
