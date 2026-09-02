{{ config(materialized = 'table') }}

SELECT
    *
FROM
    {{ref("bronze_d365_inventory_site")}}