{{ config(materialized = 'view') }}

SELECT
    pt.*
FROM
    {{ source('d365_synapse', 'purchtable') }} pt
