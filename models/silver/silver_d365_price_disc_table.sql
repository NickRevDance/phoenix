{{ config(materialized = 'table') }}

SELECT
    *
FROM
    {{ref("bronze_d365_price_disc_table")}}