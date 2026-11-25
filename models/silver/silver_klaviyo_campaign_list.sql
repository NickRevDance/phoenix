{{ config(materialized = 'table') }}

SELECT
      b.campaign_id
    , b.list_id
    , b.list_included_or_excluded
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_campaign_list') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
