{{ config(materialized = 'table') }}

{% set cols = [
      'product_option_id',
      '_fivetran_synced',
      'type',
      'display_value',
      'display_style',
      'name',
      'display_value_customer',
      'display_name_merchant',
      'id',
      'display_name_customer',
      'option_id',
      'display_name',
      'display_value_merchant',
      'order_product_id',
      'value',
      '_fivetran_deleted'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('order_product_option', cols, true) }}
)

SELECT
      u.store_code
    , u.product_option_id
    , u._fivetran_synced
    , u.type
    , u.display_value
    , u.display_style
    , u.name
    , u.display_value_customer
    , u.display_name_merchant
    , u.id
    , u.display_name_customer
    , u.option_id
    , u.display_name
    , u.display_value_merchant
    , u.order_product_id
    , u.value
FROM u
