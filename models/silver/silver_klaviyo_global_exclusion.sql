{{ config(materialized = 'table') }}

SELECT
      b.person_id
    , b.reason
    , b.timestamp
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_global_exclusion') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
