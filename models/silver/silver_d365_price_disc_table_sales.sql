{{ config(materialized = 'table') }}

{% if empty_extract_guard(ref('bronze_d365_price_disc_table'), 1) %}

SELECT
    *
FROM
    {{ this }}

{% else %}

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

{% endif %}
