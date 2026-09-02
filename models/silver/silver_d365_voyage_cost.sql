{{ config(materialized = 'table') }}

-- Voyage/shipment-level landed-cost allocation (Duty, Ocean/Air/Land
-- freight, Commission), denormalized to item+color+size. ISSELECTED and
-- TRANSFERSTATUS are both constant 0 across every row -- not real filters.
SELECT
    *
FROM
    {{ ref('bronze_d365_voyage_cost') }}
