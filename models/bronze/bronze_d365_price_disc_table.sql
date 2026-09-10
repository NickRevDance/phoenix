{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_price_disc_table') }}
