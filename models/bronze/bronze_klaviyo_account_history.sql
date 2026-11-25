{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('klaviyo', 'account_history') }} s
