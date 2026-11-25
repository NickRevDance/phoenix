{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.observed_at
    , b.test_account
    , b.contact_information_default_sender_name
    , b.contact_information_default_sender_email
    , b.contact_information_website_url
    , b.contact_information_organization_name
    , b.contact_information_street_address_address_1
    , b.contact_information_street_address_address_2
    , b.contact_information_street_address_city
    , b.contact_information_street_address_region
    , b.contact_information_street_address_country
    , b.contact_information_street_address_zip
    , b.industry
    , b.timezone
    , b.preferred_currency
    , b.public_api_key
    , b.locale
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_account_history') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
