{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.name
    , b.status
    , b.archived
    , b.trigger_type
    , b.created
    , b.updated
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_flow') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
