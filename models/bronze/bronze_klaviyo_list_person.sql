{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('klaviyo', 'list_person') }} s
