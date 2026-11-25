{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.created
    , b.updated
    , b.list_name
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_list') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
