{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('klaviyo', 'campaign') }} s
