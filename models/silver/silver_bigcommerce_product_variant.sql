{{ config(materialized = 'table') }}

{% set cols = [
      'depth',
      'calculated_price',
      'is_free_shipping',
      'retail_price',
      'calculated_weight',
      'purchasing_disabled_message',
      'sku_id',
      'cost_price',
      '_fivetran_synced',
      'weight',
      'height',
      'id',
      'product_id',
      'price',
      'inventory_level',
      'mpn',
      'upc',
      'inventory_warning_level',
      'fixed_cost_shipping_price',
      'purchasing_disabled',
      'width',
      'sku',
      'sale_price',
      'bin_picking_number',
      '_fivetran_deleted'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('product_variant', cols, true) }}
)

SELECT
      u.store_code
    , u.depth
    , u.calculated_price
    , u.is_free_shipping
    , u.retail_price
    , u.calculated_weight
    , u.purchasing_disabled_message
    , u.sku_id
    , u.cost_price
    , u._fivetran_synced
    , u.weight
    , u.height
    , u.id
    , u.product_id
    , u.price
    , u.inventory_level
    , u.mpn
    , u.upc
    , u.inventory_warning_level
    , u.fixed_cost_shipping_price
    , u.purchasing_disabled
    , u.width
    , u.sku
    , u.sale_price
    , u.bin_picking_number
FROM u
