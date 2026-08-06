{{ config(materialized = 'table') }}

SELECT
    *
FROM
    {{ref("bronze_inventory_table_module")}}
where
    moduleType = 2