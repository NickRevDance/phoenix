{{ config(materialized = 'table') }}

{% set cols = [
      'quantity_shipped',
      'return_id',
      'base_cost_price',
      'order_id',
      'external_id',
      'ebay_transaction_id',
      'wrapping_message',
      'base_price',
      '_fivetran_synced',
      'variant_id',
      'name',
      'base_wrapping_cost',
      'total_tax',
      'product_id',
      'upc',
      'price_tax',
      'total_ex_tax',
      'type',
      'wrapping_cost_tax',
      'cost_price_ex_tax',
      'ebay_item_id',
      'order_address_id',
      'option_set_id',
      'fixed_shipping_cost',
      'price_ex_tax',
      'bin_picking_number',
      'cost_price_tax',
      'event_name',
      'name_merchant',
      'id',
      'parent_order_product_id',
      'wrapping_cost_ex_tax',
      'base_total',
      'is_bundled_product',
      'event_date',
      'cost_price_inc_tax',
      'weight',
      'wrapping_cost_inc_tax',
      'name_customer',
      'is_refunded',
      'price_inc_tax',
      'sku',
      'total_inc_tax',
      'wrapping_name',
      'refunded_amount',
      'quantity',
      '_fivetran_deleted'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('order_product', cols, true) }}
)

SELECT
      u.store_code
    , u.quantity_shipped
    , u.return_id
    , TRY_CAST(u.base_cost_price AS DECIMAL(19,4)) AS base_cost_price
    , u.order_id
    , u.external_id
    , u.ebay_transaction_id
    , u.wrapping_message
    , TRY_CAST(u.base_price AS DECIMAL(19,4)) AS base_price
    , u._fivetran_synced
    , u.variant_id
    , u.name
    , TRY_CAST(u.base_wrapping_cost AS DECIMAL(19,4)) AS base_wrapping_cost
    , u.total_tax
    , u.product_id
    , u.upc
    , u.price_tax
    , u.total_ex_tax
    , u.type
    , u.wrapping_cost_tax
    , u.cost_price_ex_tax
    , u.ebay_item_id
    , u.order_address_id
    , u.option_set_id
    , TRY_CAST(u.fixed_shipping_cost AS DECIMAL(19,4)) AS fixed_shipping_cost
    , u.price_ex_tax
    , u.bin_picking_number
    , u.cost_price_tax
    , u.event_name
    , u.name_merchant
    , u.id
    , u.parent_order_product_id
    , u.wrapping_cost_ex_tax
    , TRY_CAST(u.base_total AS DECIMAL(19,4)) AS base_total
    , u.is_bundled_product
    , u.event_date
    , u.cost_price_inc_tax
    , TRY_CAST(u.weight AS DECIMAL(19,4)) AS weight
    , u.wrapping_cost_inc_tax
    , u.name_customer
    , u.is_refunded
    , u.price_inc_tax
    , u.sku
    , u.total_inc_tax
    , u.wrapping_name
    , TRY_CAST(u.refunded_amount AS DECIMAL(19,4)) AS refunded_amount
    , u.quantity
FROM u
