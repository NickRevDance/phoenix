{{ config(materialized = 'view') }}

SELECT
    mt.*
FROM
    {{ source('d365_synapse', 'markuptrans') }} mt
