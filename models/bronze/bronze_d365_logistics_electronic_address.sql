{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source("byod", "d365_logistics_electronic_address") }}
