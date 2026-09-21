-- Exactly one is_current_row = true version per purchase_order_id +
-- purchase_order_line_number + source_system. Unlike fact_product_price's
-- price windows (which can legitimately expire with zero current rows),
-- every PO line in this real SCD2 change-event fact always has a standing
-- current state, so both zero and multiple current rows are failures here.

select
      purchase_order_id
    , purchase_order_line_number
    , source_system
    , sum(case when is_current_row then 1 else 0 end) as current_row_count
from {{ ref('fact_purchase_order') }}
group by purchase_order_id, purchase_order_line_number, source_system
having sum(case when is_current_row then 1 else 0 end) <> 1
