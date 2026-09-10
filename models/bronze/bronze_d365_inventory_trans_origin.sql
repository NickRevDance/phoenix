{{ config(materialized = 'view') }}

select
    *
From
    {{source('byod', 'd365_inventory_trans_origin')}}
