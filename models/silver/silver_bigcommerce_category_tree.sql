{{ config(materialized = 'table') }}

{% set cols = [
      'layout_file',
      'sort_order',
      'tree_id',
      'path',
      'image_url',
      'name',
      '_fivetran_synced',
      'category_id',
      'parent_id',
      'meta_description',
      'page_title',
      'is_customized',
      'views',
      'category_uuid',
      'default_product_sort',
      'search_keywords',
      'description',
      'is_visible',
      '_fivetran_deleted'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('category_tree', cols, true) }}
)

SELECT
      u.store_code
    , u.layout_file
    , u.sort_order
    , u.tree_id
    , u.path
    , u.image_url
    , u.name
    , u._fivetran_synced
    , u.category_id
    , u.parent_id
    , u.meta_description
    , u.page_title
    , u.is_customized
    , u.views
    , u.category_uuid
    , u.default_product_sort
    , u.search_keywords
    , u.description
    , u.is_visible
FROM u
