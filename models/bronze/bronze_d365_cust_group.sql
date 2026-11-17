{{ config(materialized = 'view') }}

SELECT
    cg.*
FROM
    {{ source('d365_synapse', 'custgroup') }} cg
