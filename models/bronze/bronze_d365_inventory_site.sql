{{ config(materialized = 'view') }}

SELECT
    *
from
    {{source("byod", "inventory_site")}}