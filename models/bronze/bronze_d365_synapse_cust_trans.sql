{{ config(materialized = 'view') }}

SELECT
    ct.*
FROM
    {{ source('d365_synapse', 'custtrans') }} ct
