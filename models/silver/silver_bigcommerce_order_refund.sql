{{ config(materialized = 'table') }}

{% set cols = [
      'total_amount',
      'uses_merchant_override_values',
      'user_id',
      '_fivetran_synced',
      'id',
      'total_tax',
      'order_id',
      'created',
      'reason'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('order_refund', cols, false) }}
)

SELECT
      u.store_code
    , u.total_amount
    , u.uses_merchant_override_values
    , u.user_id
    , u._fivetran_synced
    , u.id
    , u.total_tax
    , u.order_id
    , u.created
    , u.reason
FROM u
