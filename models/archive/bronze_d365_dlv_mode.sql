{{ config(materialized = 'view') }}

SELECT
    dm.*
FROM
    {{ source('d365_synapse', 'dlvmode') }} dm
