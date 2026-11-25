{{ config(materialized = 'table') }}

SELECT
      b.list_id
    , b.tag_id
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_list_tag') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
