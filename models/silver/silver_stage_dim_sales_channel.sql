SELECT

      TRIM(channel_code)                    AS channel_code
    , TRIM(channel_name)                    AS channel_name
    , NULLIF(TRIM(channel_short_name), '')  AS channel_short_name
    , NULLIF(TRIM(storefront_code), '')     AS storefront_code
    , NULLIF(TRIM(storefront_platform), '') AS storefront_platform
    , CAST(is_loyalty_eligible AS INT)      AS is_loyalty_eligible
    , CAST(is_promotion_eligible AS INT)    AS is_promotion_eligible
    , CAST(is_returns_enabled AS INT)       AS is_returns_enabled
    , TRIM(channel_status)                  AS channel_status
    , CAST(sort_order AS INT)               AS sort_order

FROM {{ ref('sales_channel') }}
