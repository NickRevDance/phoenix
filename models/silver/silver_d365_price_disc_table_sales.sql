{{ config(materialized = 'table') }}

-- MODULE = 1 (Sales) per D365's PriceDiscTable module enum -- the sibling
-- population to silver_d365_price_disc_table's MODULE = 2 (Purchase) filter.
-- Sales-side trade agreement/pricing records: source for FACT_PRODUCT_PRICE's
-- LIST/SALE/B2B price types.
SELECT
    *
FROM
    {{ ref('bronze_d365_price_disc_table') }}
WHERE
    MODULE = 1
