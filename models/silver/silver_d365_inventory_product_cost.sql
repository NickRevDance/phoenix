{{ config(materialized = 'table') }}

SELECT
    *
FROM
    {{ref("bronze_d365_inventory_table_module")}}
where
    moduleType = 2