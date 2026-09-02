{{ config(materialized = 'table') }}

-- MODULETYPE = 0 (Inventory) per D365's InventTableModule enum -- 1 = Purch,
-- 2 = Sales. The old filter (moduleType = 2) was pulling selling price, not
-- inventory/standard cost.
SELECT
    *
FROM
    {{ref("bronze_d365_inventory_table_module")}}
where
    moduleType = 0
