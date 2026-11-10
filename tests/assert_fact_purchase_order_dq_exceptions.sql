{{ config(severity = 'warn') }}

-- FACT_PURCHASE_ORDER source exceptions (spec 4.1, 4.5, 4.8, 8.5): flagged for follow-up, never fail the run.
with po as (

    select *
    from {{ ref('fact_purchase_order') }}
    where is_current_row = 1

)

select po.purchase_order_id, po.purchase_order_line_number, 'quantity outlier (abs ordered_qty > 1,000,000)' as exception_type
from po
where po.is_quantity_outlier_flag = 1

union all

select po.purchase_order_id, po.purchase_order_line_number, 'VENDOR line invoiced with no in-transit row (received_qty from the D365 formula)'
from po
where po.purchase_order_class = 'VENDOR'
  and po.po_line_status = 'Invoiced'
  and po.goods_in_transit_id is null

union all

select po.purchase_order_id, po.purchase_order_line_number, 'negative ordered_qty on a VENDOR line'
from po
where po.purchase_order_class = 'VENDOR'
  and po.ordered_qty < 0

union all

select po.purchase_order_id, po.purchase_order_line_number, 'unmapped document_status or approval_state'
from po
where po.document_status not in ('None', 'Purchase Order', 'Product Receipt', 'Invoice')
   or po.approval_state not in ('Approved', 'Confirmed')
