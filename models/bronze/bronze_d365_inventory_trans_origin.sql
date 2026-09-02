{{ config(materialized = 'view') }}

select
    *
From
    {{source('byod', 'inventory_trans_origin')}}