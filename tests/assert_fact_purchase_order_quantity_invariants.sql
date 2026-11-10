{{ config(severity = 'error', warn_if = '>0', error_if = '>25') }}

-- FACT_PURCHASE_ORDER spec 8.3 invariants on current VENDOR rows, plus version 1 being the current row (8.9).
with po as (

    select *
    from {{ ref('fact_purchase_order') }}
    where version_number = 1

)

select po.purchase_order_id, po.purchase_order_line_number, 'backorder line has receipts or open differs from remaining physical' as failure_reason
from po
where po.purchase_order_class = 'VENDOR'
  and po.po_line_status = 'Backorder'
  and (po.received_qty <> 0 or po.open_qty <> po.remaining_physical_qty)

union all

select po.purchase_order_id, po.purchase_order_line_number, 'invoiced line not invoiced for its ordered quantity'
from po
where po.purchase_order_class = 'VENDOR'
  and po.po_line_status = 'Invoiced'
  and po.invoiced_qty <> po.ordered_qty

union all

select po.purchase_order_id, po.purchase_order_line_number, 'invoiced line: received + in transit differs from invoiced'
from po
where po.purchase_order_class = 'VENDOR'
  and po.po_line_status = 'Invoiced'
  and po.received_qty + po.in_transit_qty <> po.invoiced_qty

union all

select po.purchase_order_id, po.purchase_order_line_number, 'received exceeds ordered'
from po
where po.received_qty > po.ordered_qty

union all

select po.purchase_order_id, po.purchase_order_line_number, 'latest version is not flagged current while its range is open'
from po
where po.effective_end_datetime is null
  and po.is_current_row <> 1
