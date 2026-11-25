{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.name
    , b.status
    , b.ab_test
    , b.created_at
    , b.updated_at
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_form') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
