{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source("byod", "d365_logistics_postal_address") }}
