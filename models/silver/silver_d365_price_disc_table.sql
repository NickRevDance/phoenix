{{ config(materialized = 'table') }}

-- MODULE = 2 (Purchase) per D365's PriceDiscTable module enum -- confirmed
-- against live data via ACCOUNTRELATION overlap with VendTable (20 of 21
-- accounts match; MODULE = 1 rows are Sales/customer agreements, 0 match).
SELECT
    *
FROM
    {{ ref('bronze_d365_price_disc_table') }}
WHERE
    MODULE = 2
