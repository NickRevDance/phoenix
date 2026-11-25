{{ config(materialized = 'table') }}

{% set cols = [
      'origin_channel_id',
      '_fivetran_synced',
      'customer_group_id',
      'accepts_product_review_abandoned_cart_emails',
      'company',
      'force_password_reset',
      'tax_exempt_category',
      'notes',
      'date_modified',
      'date_created',
      'attribute_count',
      'first_name',
      'last_name',
      'phone',
      'address_count',
      'email',
      'registration_ip_address',
      'id',
      '_fivetran_deleted'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('customer', cols, true) }}
)

SELECT
      u.store_code
    , u.origin_channel_id
    , u._fivetran_synced
    , u.customer_group_id
    , u.accepts_product_review_abandoned_cart_emails
    , u.company
    , u.force_password_reset
    , u.tax_exempt_category
    , u.notes
    , u.date_modified
    , u.date_created
    , u.attribute_count
    , u.first_name
    , u.last_name
    , u.phone
    , u.address_count
    , NULLIF(LOWER(TRIM(u.email)), '') AS email
    , u.registration_ip_address
    , u.id
FROM u
