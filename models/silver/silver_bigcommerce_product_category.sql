{{ config(materialized = 'table') }}

{% set cols = [
      'product_id',
      '_fivetran_synced',
      'category_id',
      '_fivetran_deleted'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('product_category', cols, true) }}
)

SELECT
      u.store_code
    , u.product_id
    , u._fivetran_synced
    , u.category_id
FROM u
