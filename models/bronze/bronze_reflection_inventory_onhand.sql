{{ config(materialized = 'view') }}

select * from {{ source('d365_reflection', 'inventory_onhand') }}
