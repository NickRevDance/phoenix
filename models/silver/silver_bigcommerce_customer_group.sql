{{ config(materialized = 'table') }}

{% set cols = [
      'name',
      'id',
      'is_default',
      '_fivetran_synced',
      'is_group_for_guests',
      '_fivetran_deleted'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('customer_group', cols, true) }}
)

SELECT
      u.store_code
    , u.name
    , u.id
    , u.is_default
    , u._fivetran_synced
    , u.is_group_for_guests
FROM u
