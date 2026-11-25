{{ config(materialized = 'table') }}

-- Custom profile properties land as custom_* columns (Fivetran unpacked mode) and are carried through as they appear.

SELECT
      b.* EXCEPT (b.email, b._fivetran_deleted)
    , NULLIF(LOWER(TRIM(b.email)), '') AS email
FROM {{ ref('bronze_klaviyo_person') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
