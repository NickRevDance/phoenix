-- Spec Section 10: price_currency_code loads straight from CURRENCY with
-- no default. Blank/null never occurred in the 2026-09-15 profiling --
-- if this ever returns rows, they've been silently defaulting to nothing
-- rather than raising the DQ exception the spec calls for.

select
      ITEMRELATION
    , INVENTDIMID
    , CURRENCY
from {{ ref('silver_d365_price_disc_table_sales') }}
where ACCOUNTCODE = 2
  and ITEMCODE = 0
  and QUANTITYAMOUNTFROM = 0
  and AMOUNT <> 0
  and (CURRENCY is null or CURRENCY = '')
