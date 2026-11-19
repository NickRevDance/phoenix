{{ config(materialized = 'view') }}

SELECT
    ma.*
FROM
    {{ source('d365_synapse', 'mainaccount') }} ma
