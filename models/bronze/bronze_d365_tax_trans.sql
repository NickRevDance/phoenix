{{ config(materialized = 'view') }}

SELECT
    tt.*
FROM
    {{ source('d365_synapse', 'taxtrans') }} tt
