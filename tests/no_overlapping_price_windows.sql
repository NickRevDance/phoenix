{{ config(severity = 'warn') }}

-- Business Rule 8.3: windows for the same variant + price_type + currency
-- must not overlap. A window's expiration_date should never fall after
-- the next window's effective_date in the same series.
--
-- Confirmed live 2026-09-15: this returns ~5,624 rows (3.8% of the
-- deduped population), not zero. Sampled cases cluster around one
-- specific pair of dates -- a window opened 2023-03-01 and closed
-- 2023-08-02 overlaps a next window that opened 2023-07-16, a 17-day
-- overlap repeated across many unrelated variants -- consistent with one
-- bulk repricing event where the old agreements' TODATE wasn't trimmed to
-- match the new batch's start. Real source data quality, not a bug in
-- this build's window loading (confirmed against the raw FROMDATE/TODATE
-- values directly, no transformation involved). Left at severity: warn
-- so it's visible without blocking every build -- worth a Merchandising/
-- D365 conversation about whether these bulk-update overlaps are
-- expected or a source-side cleanup opportunity.

with sequenced as (

    select
          product_key
        , price_type
        , price_currency_code
        , effective_date
        , expiration_date
        , lead(effective_date) over (
            partition by product_key, price_type, price_currency_code
            order by effective_date
          ) as next_effective_date
    from {{ ref('fact_product_price') }}
    where product_key <> '-1'

)

select *
from sequenced
where expiration_date is not null
  and next_effective_date is not null
  and expiration_date > next_effective_date
