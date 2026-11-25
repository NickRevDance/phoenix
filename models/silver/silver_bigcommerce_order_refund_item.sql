{{ config(materialized = 'table') }}

{% set cols = [
      'quantity',
      'item_type',
      'item_id',
      'requested_amount',
      'order_refund_id',
      'reason',
      '_fivetran_synced'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('order_refund_item', cols, false) }}
)

SELECT
      u.store_code
    , u.quantity
    , u.item_type
    , u.item_id
    , u.requested_amount
    , u.order_refund_id
    , u.reason
    , u._fivetran_synced
FROM u
