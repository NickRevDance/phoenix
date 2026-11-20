{{ config(materialized = 'table') }}

-- NEEDS CONFIRMATION: integration users are picked out by UserType plus the integration account names seen in Nov 2026.
SELECT
      b.*
    , CASE
        WHEN b.UserType IN ('AutomatedProcess', 'CloudIntegrationUser')
          OR (b.UserType = 'Standard' AND (b.Name RLIKE '(?i)\\bintegration\\b' OR b.Name RLIKE '(?i)^api account'))
            THEN 'Integration'
        WHEN b.UserType = 'Standard' THEN 'Internal'
        WHEN b.UserType IN ('PowerCustomerSuccess', 'CustomerSuccess', 'CspLitePortal') THEN 'Customer Portal'
        WHEN b.UserType IN ('PowerPartner', 'Partner') THEN 'Partner Portal'
        WHEN b.UserType = 'Guest' THEN 'Guest'
        ELSE 'Other'
      END AS user_category
FROM {{ ref('bronze_sfdc_user') }} b
