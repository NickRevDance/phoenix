{{ config(materialized = 'table') }}

{% set cols = [
      '_fivetran_synced',
      'code',
      'id',
      'target',
      'name',
      'amount',
      'order_product_id',
      '_fivetran_deleted'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('order_product_discount', cols, true) }}
)

SELECT
      u.store_code
    , u._fivetran_synced
    , u.code
    , u.id
    , u.target
    , u.name
    , TRY_CAST(u.amount AS DECIMAL(19,4)) AS amount
    , u.order_product_id
FROM u
