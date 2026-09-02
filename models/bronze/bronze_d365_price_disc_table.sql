{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'price_disc_table') }}