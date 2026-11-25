{{ config(materialized = 'table') }}

{% set cols = [
      'image_url',
      'page_title',
      'meta_description',
      'name',
      'custom_url_is_customized',
      'search_keywords',
      'id',
      'custom_url',
      '_fivetran_synced',
      '_fivetran_deleted'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('brand', cols, true) }}
)

SELECT
      u.store_code
    , u.image_url
    , u.page_title
    , u.meta_description
    , u.name
    , u.custom_url_is_customized
    , u.search_keywords
    , u.id
    , u.custom_url
    , u._fivetran_synced
FROM u
