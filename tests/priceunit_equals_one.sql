-- Spec Section 10 assertion: PRICEUNIT is 1 throughout the Phase 1
-- population. list_price is loaded straight from AMOUNT on the assumption
-- that PRICEUNIT = 1 always (i.e. AMOUNT is already a per-unit price) --
-- if this ever returns rows, list_price needs to divide by PRICEUNIT
-- instead of using AMOUNT as-is.

select
      ITEMRELATION
    , INVENTDIMID
    , PRICEUNIT
from {{ ref('silver_d365_price_disc_table_sales') }}
where ACCOUNTCODE = 2
  and ITEMCODE = 0
  and QUANTITYAMOUNTFROM = 0
  and AMOUNT <> 0
  and PRICEUNIT <> 1
