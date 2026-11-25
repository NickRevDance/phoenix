{{ config(materialized = 'table') }}

{% set cols = [
      'domain',
      'admin_email',
      'is_price_entered_with_tax',
      'plan_is_trial',
      'facebook_catalog_id',
      'decimal_separator',
      'multi_storefront_enabled',
      'default_site_id',
      'order_email',
      'plan_name',
      'account_uuid',
      'dimension_thousands_token',
      'timezone_dst_offset',
      'name',
      'id',
      'timezone_name',
      'languages',
      'status',
      'plan_level',
      'dimension_decimal_places',
      'default_channel_id',
      'logo_url',
      'timezone_extended_display',
      'sitewidehttps_enabled',
      'decimal_places',
      'currency',
      'thousands_separator',
      'industry',
      'graphql_storefront_api_enabled',
      'secure_url',
      '_fivetran_synced',
      'currency_symbol_location',
      'timezone_raw_offset',
      'phone',
      'dimension_units',
      'weight_units',
      'checkout_type',
      'first_name',
      'last_name',
      'timezone_dst_correction',
      'store_id',
      'stencil_enabled',
      'country',
      'wishlists_enabled',
      'timezone_export',
      'address',
      'control_panel_base_url',
      'dimension_decimal_token',
      'currency_symbol',
      'timezone_display',
      'shopper_consent_tracking_enabled',
      '_fivetran_deleted'
] %}

WITH u AS (
    {{ union_bigcommerce_stores('store', cols, true) }}
)

SELECT
      u.store_code
    , u.domain
    , u.admin_email
    , u.is_price_entered_with_tax
    , u.plan_is_trial
    , u.facebook_catalog_id
    , u.decimal_separator
    , u.multi_storefront_enabled
    , u.default_site_id
    , u.order_email
    , u.plan_name
    , u.account_uuid
    , u.dimension_thousands_token
    , u.timezone_dst_offset
    , u.name
    , u.id
    , u.timezone_name
    , u.languages
    , u.status
    , u.plan_level
    , u.dimension_decimal_places
    , u.default_channel_id
    , u.logo_url
    , u.timezone_extended_display
    , u.sitewidehttps_enabled
    , u.decimal_places
    , u.currency
    , u.thousands_separator
    , u.industry
    , u.graphql_storefront_api_enabled
    , u.secure_url
    , u._fivetran_synced
    , u.currency_symbol_location
    , u.timezone_raw_offset
    , u.phone
    , u.dimension_units
    , u.weight_units
    , u.checkout_type
    , u.first_name
    , u.last_name
    , u.timezone_dst_correction
    , u.store_id
    , u.stencil_enabled
    , u.country
    , u.wishlists_enabled
    , u.timezone_export
    , u.address
    , u.control_panel_base_url
    , u.dimension_decimal_token
    , u.currency_symbol
    , u.timezone_display
    , u.shopper_consent_tracking_enabled
FROM u
