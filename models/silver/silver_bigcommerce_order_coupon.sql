{{ config(materialized = 'table') }}

{% set cols = [
      '_fivetran_synced',
      'type',
      'coupon_id',
      'order_id',
      'code',
      'discount',
      'amount',
      'id',
      '_fivetran_deleted'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('order_coupon', cols, true) }}
)

SELECT
      u.store_code
    , u._fivetran_synced
    , u.type
    , u.coupon_id
    , u.order_id
    , u.code
    , u.discount
    , u.amount
    , u.id
FROM u
