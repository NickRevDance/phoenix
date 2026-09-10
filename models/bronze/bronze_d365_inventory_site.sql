{{ config(materialized = 'view') }}

SELECT
    *
from
    {{source("byod", "d365_inventory_site")}}
