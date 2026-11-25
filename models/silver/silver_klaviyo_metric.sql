{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.name
    , b.created
    , b.updated
    , b.integration_object
    , b.integration_id
    , b.integration_name
    , b.integration_category
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_metric') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
