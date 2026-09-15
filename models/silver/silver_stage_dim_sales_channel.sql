SELECT

      TRIM(channel_code)                              AS channel_code
    , TRIM(channel_name)                               AS channel_name
    , NULLIF(TRIM(channel_short_name), '')             AS channel_short_name
    , NULLIF(TRIM(channel_description), '')            AS channel_description
    , NULLIF(TRIM(channel_subtype), '')                AS channel_subtype
    , NULLIF(TRIM(storefront_code), '')                AS storefront_code
    , NULLIF(TRIM(storefront_platform), '')            AS storefront_platform
    , CAST(is_loyalty_redemption_channel AS BOOLEAN)   AS is_loyalty_redemption_channel
    , CAST(loyalty_redemption_start_date AS DATE)      AS loyalty_redemption_start_date
    , CAST(is_promotion_eligible AS BOOLEAN)           AS is_promotion_eligible
    , CAST(is_returns_enabled AS BOOLEAN)              AS is_returns_enabled
    , TRIM(channel_status)                             AS channel_status
    , CAST(channel_start_date AS DATE)                 AS channel_start_date
    , CAST(sort_order AS INT)                          AS sort_order

FROM {{ ref('sales_channel') }}
