{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.name
    , b.tag_group_id
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_tags') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
