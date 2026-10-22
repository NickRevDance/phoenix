{{ config(severity = 'warn') }}

-- EDW-50 / Inventory spec 3.3 (v2.2 STATUS_CHANGE rule): each status change is two legs on the same
-- reference, date, product and warehouse: one issue leg out of the from-status (negative) and one
-- receipt leg into the to-status (positive). They net to zero, each carries the other side's status
-- as its counterparty, and both carry the same from/to availability pair. Returns one row per pair
-- that breaks any of that, with the reason.

with legs as (

    select

          f.source_document_id
        , f.movement_date_key
        , f.product_id
        , f.warehouse_key
        , f.quantity_change
        , f.inventory_status_code
        , f.counterparty_inventory_status_code
        , f.from_availability_status
        , f.to_availability_status

    from {{ ref('fact_inventory_movement') }} f
    where f.movement_type = 'STATUS_CHANGE'

),

pairs as (

    select

          l.source_document_id
        , l.movement_date_key
        , l.product_id
        , l.warehouse_key
        , sum(l.quantity_change) as net_qty
        , count_if(l.quantity_change < 0) as issue_legs
        , count_if(l.quantity_change >= 0) as receipt_legs
        , max(case when l.quantity_change < 0 then l.inventory_status_code end) as from_status
        , max(case when l.quantity_change >= 0 then l.inventory_status_code end) as to_status
        , max(case when l.quantity_change < 0 then l.counterparty_inventory_status_code end) as issue_counterparty
        , max(case when l.quantity_change >= 0 then l.counterparty_inventory_status_code end) as receipt_counterparty
        , count(distinct coalesce(l.from_availability_status, '~')) as from_availability_values
        , count(distinct coalesce(l.to_availability_status, '~')) as to_availability_values

    from legs l
    group by 1, 2, 3, 4

)

select

      p.*
    , case
        when p.issue_legs <> 1 or p.receipt_legs <> 1 then 'not exactly one leg per side'
        when p.net_qty <> 0 then 'legs do not net to zero'
        when not (p.issue_counterparty <=> p.to_status) or not (p.receipt_counterparty <=> p.from_status) then 'counterparty status does not match the other leg'
        else 'availability pair differs between the two legs'
      end as failure_reason

from pairs p
where p.issue_legs <> 1
   or p.receipt_legs <> 1
   or p.net_qty <> 0
   or not (p.issue_counterparty <=> p.to_status)
   or not (p.receipt_counterparty <=> p.from_status)
   or p.from_availability_values > 1
   or p.to_availability_values > 1
