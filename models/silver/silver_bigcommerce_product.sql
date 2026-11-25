{{ config(materialized = 'table') }}

{% set cols = [
      'gift_wrapping_options_type',
      'brand_id',
      'depth',
      'is_free_shipping',
      'sku',
      'custom_url',
      'warranty',
      'search_keywords',
      'availability_description',
      'meta_description',
      'condition',
      'option_set_id',
      'is_price_hidden',
      'gtin',
      'map_price',
      'is_preorder_hidden',
      'view_count',
      'bin_picking_number',
      'retail_price',
      'is_condition_shown',
      'preorder_release_date',
      'is_visible',
      'id',
      'is_preorder_only',
      'custom_url_is_customized',
      'order_quantity_maximum',
      'weight',
      'brand_name',
      'date_modified',
      'mpn',
      'base_variant_id',
      'option_set_display',
      'sort_order',
      'description',
      'cost_price',
      'total_sold',
      'fixed_cost_shipping_price',
      'layout_file',
      'inventory_tracking',
      'open_graph_use_meta_description',
      'height',
      'price',
      'open_graph_type',
      'is_featured',
      'reviews_rating_sum',
      'inventory_warning_level',
      'open_graph_title',
      '_fivetran_synced',
      'sale_price',
      'name',
      'product_tax_code',
      'availability',
      'width',
      'order_quantity_minimum',
      'inventory_level',
      'open_graph_use_image',
      'upc',
      'page_title',
      'preorder_message',
      'date_created',
      'reviews_count',
      'open_graph_use_product_name',
      'open_graph_description',
      'type',
      'calculated_price',
      'price_hidden_label',
      'tax_class_id',
      '_fivetran_deleted'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('product', cols, true) }}
)

SELECT
      u.store_code
    , u.gift_wrapping_options_type
    , u.brand_id
    , u.depth
    , u.is_free_shipping
    , u.sku
    , u.custom_url
    , u.warranty
    , u.search_keywords
    , u.availability_description
    , u.meta_description
    , u.condition
    , u.option_set_id
    , u.is_price_hidden
    , u.gtin
    , u.map_price
    , u.is_preorder_hidden
    , u.view_count
    , u.bin_picking_number
    , u.retail_price
    , u.is_condition_shown
    , u.preorder_release_date
    , u.is_visible
    , u.id
    , u.is_preorder_only
    , u.custom_url_is_customized
    , u.order_quantity_maximum
    , u.weight
    , u.brand_name
    , u.date_modified
    , u.mpn
    , u.base_variant_id
    , u.option_set_display
    , u.sort_order
    , u.description
    , u.cost_price
    , u.total_sold
    , u.fixed_cost_shipping_price
    , u.layout_file
    , u.inventory_tracking
    , u.open_graph_use_meta_description
    , u.height
    , u.price
    , u.open_graph_type
    , u.is_featured
    , u.reviews_rating_sum
    , u.inventory_warning_level
    , u.open_graph_title
    , u._fivetran_synced
    , u.sale_price
    , u.name
    , u.product_tax_code
    , u.availability
    , u.width
    , u.order_quantity_minimum
    , u.inventory_level
    , u.open_graph_use_image
    , u.upc
    , u.page_title
    , u.preorder_message
    , u.date_created
    , u.reviews_count
    , u.open_graph_use_product_name
    , u.open_graph_description
    , u.type
    , u.calculated_price
    , u.price_hidden_label
    , u.tax_class_id
FROM u
