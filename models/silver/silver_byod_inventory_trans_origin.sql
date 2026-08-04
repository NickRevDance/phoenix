{{ config(materialized = 'table') }}

select
    *
from
    {{ref("bronze_byod_inventory_trans_origin")}}