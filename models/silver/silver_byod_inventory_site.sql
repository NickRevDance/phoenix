{{ config(materialized = 'table') }}

SELECT
    *
FROM
    {{ref("bronze_byod_inventory_site")}}