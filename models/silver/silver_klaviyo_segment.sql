{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.name
    , b.definition
    , b.created
    , b.updated
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_segment') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
