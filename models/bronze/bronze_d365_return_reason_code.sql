{{ config(materialized = 'view') }}

SELECT
    src.*
FROM
    {{ source('byod', 'd365_return_reason_code') }} src
