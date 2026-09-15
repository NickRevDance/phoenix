-- Business Rule 8.3: at most one is_current = 1 row per product_key +
-- price_type + price_currency_code -- the DQ tie-break (latest FROMDATE,
-- then latest MODIFIEDDATE, wins) must never leave two rows both current.
-- Flags only sum(is_current) > 1, not <> 1: a series whose last window is
-- closed with no successor is legitimately price_status = 'Expired' with
-- ZERO current rows (the variant has no standing price in that currency
-- -- see the Field Catalog), and that's expected, not a failure.
-- Excludes product_key = '-1' -- every unresolved variant collapses into
-- that one key by design (Open Decision #9), so a uniqueness check on it
-- would always fail for a reason that has nothing to do with this rule.

select
      product_key
    , price_type
    , price_currency_code
    , sum(case when is_current then 1 else 0 end) as current_row_count
from {{ ref('fact_product_price') }}
where product_key <> '-1'
group by product_key, price_type, price_currency_code
having sum(case when is_current then 1 else 0 end) > 1
