{{ config(materialized = 'table') }}

{% set cols = [
      'customer_id',
      'id',
      'handling_cost_tax',
      'date_shipped',
      'product_resource',
      'cart_id',
      'external_source',
      'total_ex_tax',
      'subtotal_tax',
      'ebay_order_id',
      'channel_id',
      'handling_cost_tax_class_id',
      'zip',
      'store_default_currency_code',
      '_fivetran_synced',
      'handling_cost_inc_tax',
      'total_inc_tax',
      'shipping_cost_tax_class_id',
      'wrapping_cost_inc_tax',
      'payment_method',
      'subtotal_ex_tax',
      'street_2',
      'city',
      'default_currency_code',
      'refunded_amount',
      'discount_amount',
      'last_name',
      'currency_code',
      'external_id',
      'base_handling_cost',
      'shipping_addressresource',
      'shipping_cost_inc_tax',
      'first_name',
      'wrapping_cost_tax_class_id',
      'is_deleted',
      'status',
      'order_is_digital',
      'base_wrapping_cost',
      'shipping_address_count',
      'items_total',
      'ip_address_v_6',
      'coupon_discount',
      'shipping_cost_tax',
      'phone',
      'coupon_url',
      'currency_exchange_rate',
      'staff_notes',
      'status_id',
      'wrapping_cost_ex_tax',
      'date_modified',
      'is_email_opt_in',
      'wrapping_cost_tax',
      'subtotal_inc_tax',
      'store_credit_amount',
      'external_merchant_id',
      'coupon_resource',
      'state',
      'customer_locale',
      'date_created',
      'tax_provider_id',
      'items_shipped',
      'ip_address',
      'payment_status',
      'street_1',
      'handling_cost_ex_tax',
      'payment_provider_id',
      'base_shipping_cost',
      'shipping_addressurl',
      'customer_message',
      'default_currency_id',
      'geoip_country_iso_2',
      'gift_certificate_amount',
      'product_url',
      'country',
      'country_iso_2',
      'shipping_cost_ex_tax',
      'geoip_country',
      'email',
      'store_default_to_transactional_exchange_rate',
      'company',
      'order_source',
      'currency_id',
      '_fivetran_deleted'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('orders', cols, true) }}
)

SELECT
      u.store_code
    , u.customer_id
    , u.id
    , u.handling_cost_tax
    , u.date_shipped
    , u.product_resource
    , u.cart_id
    , u.external_source
    , u.total_ex_tax
    , u.subtotal_tax
    , u.ebay_order_id
    , u.channel_id
    , u.handling_cost_tax_class_id
    , u.zip
    , u.store_default_currency_code
    , u._fivetran_synced
    , u.handling_cost_inc_tax
    , u.total_inc_tax
    , u.shipping_cost_tax_class_id
    , u.wrapping_cost_inc_tax
    , u.payment_method
    , u.subtotal_ex_tax
    , u.street_2
    , u.city
    , u.default_currency_code
    , u.refunded_amount
    , u.discount_amount
    , u.last_name
    , u.currency_code
    , u.external_id
    , u.base_handling_cost
    , u.shipping_addressresource
    , u.shipping_cost_inc_tax
    , u.first_name
    , u.wrapping_cost_tax_class_id
    , u.is_deleted
    , u.status
    , u.order_is_digital
    , u.base_wrapping_cost
    , u.shipping_address_count
    , u.items_total
    , u.ip_address_v_6
    , u.coupon_discount
    , u.shipping_cost_tax
    , u.phone
    , u.coupon_url
    , u.currency_exchange_rate
    , u.staff_notes
    , u.status_id
    , u.wrapping_cost_ex_tax
    , u.date_modified
    , u.is_email_opt_in
    , u.wrapping_cost_tax
    , u.subtotal_inc_tax
    , u.store_credit_amount
    , u.external_merchant_id
    , u.coupon_resource
    , u.state
    , u.customer_locale
    , u.date_created
    , u.tax_provider_id
    , u.items_shipped
    , u.ip_address
    , u.payment_status
    , u.street_1
    , u.handling_cost_ex_tax
    , u.payment_provider_id
    , u.base_shipping_cost
    , u.shipping_addressurl
    , u.customer_message
    , u.default_currency_id
    , u.geoip_country_iso_2
    , u.gift_certificate_amount
    , u.product_url
    , u.country
    , u.country_iso_2
    , u.shipping_cost_ex_tax
    , u.geoip_country
    , NULLIF(LOWER(TRIM(u.email)), '') AS email
    , u.store_default_to_transactional_exchange_rate
    , u.company
    , u.order_source
    , u.currency_id
    , CAST(from_utc_timestamp(u.date_created, st.timezone_name) AS DATE) AS order_date
    , CAST(u.total_inc_tax - u.total_ex_tax AS DECIMAL(19,4)) AS total_tax_amount
    , (
          NOT COALESCE(u.is_deleted, false)
          AND u.status NOT IN ('Incomplete', 'Cancelled', 'Declined', 'Pending', 'Awaiting Payment')
          AND COALESCE(u.payment_status, '') <> 'declined'
      ) AS is_sale_order
FROM u
LEFT JOIN {{ ref('silver_bigcommerce_store') }} st
    ON st.store_code = u.store_code
