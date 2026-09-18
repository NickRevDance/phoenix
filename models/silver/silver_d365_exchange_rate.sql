{{ config(materialized = 'table') }}

-- EDW-94: one row per (from_currency, valid date range), USD-denominated
-- spot rate. D365's native ExchangeRate export stores EXCHANGERATE as USD
-- per 100 units of the from-currency (confirmed against live data: CAD rows
-- average ~72, GBP rows ~124 -- dividing by 100 lines up with real-world
-- CAD/USD (~0.72) and GBP/USD (~1.24) spot levels for the same dates).
-- Only CAD->USD and GBP->USD are present today (monthly snapshots); every
-- other currency has no rate row, so a lookup miss stays null rather than
-- guessing. No REF_FX_RATE / currency-normalization standard exists yet
-- (EDW-127, unspecced) -- this reads D365's own spot rate directly as an
-- interim source, not a modeled conformed dimension.

SELECT

      r.EXCHANGERATECURRENCYPAIR_FROMCURRENCYCODE as from_currency_code
    , r.EXCHANGERATECURRENCYPAIR_TOCURRENCYCODE as to_currency_code
    , cast(r.EXCHANGERATE / 100 as decimal(19,8)) as fx_rate_to_usd
    , cast(r.VALIDFROM as date) as valid_from_date
    , cast(r.VALIDTO as date) as valid_to_date
    , r.MODIFIEDDATE as d365_modified_datetime

FROM {{ source('byod', 'd365_exchange_rate') }} r
WHERE r.EXCHANGERATECURRENCYPAIR_TOCURRENCYCODE = 'USD'
    and r.EXCHANGERATETYPE_NAME = 'Spot'
