{{ config(materialized = 'view') }}

select * from {{ source('dwhvisualnext', 'kpi_inventory_value') }}
