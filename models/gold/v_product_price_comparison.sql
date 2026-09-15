{{ config(materialized = 'view') }}

-- v1.1 change (spec Section 9.3): list_vs_msrp_variance removed -- there
-- is no MSRP (Open Decision #2, closed: not maintained). cad_usd_ratio
-- replaces the old msrp/b2b comparison columns as the Phase 1 signal;
-- the exception flag surfaces variants priced outside the normal
-- ~1.33-1.40x CAD/USD band (spec Section 3.1, p10-p90 of the live ratio).

select

      c.product_key
    , c.product_id
    , c.sku
    , c.list_price_usd
    , c.list_price_cad

    , case when c.list_price_usd is not null and c.list_price_usd <> 0
        then c.list_price_cad / c.list_price_usd
      end as cad_usd_ratio
    , case
        when c.list_price_usd is not null and c.list_price_usd <> 0 and c.list_price_cad is not null
          and (c.list_price_cad / c.list_price_usd < 1.30 or c.list_price_cad / c.list_price_usd > 1.45)
        then true
        else false
      end as cad_usd_ratio_exception_flag

    , cast(null as decimal(9,4)) as list_vs_sale_discount_pct  -- Phase 2
    , cast(null as decimal(9,4)) as b2b_vs_list_discount_pct  -- Phase 2

from {{ ref('v_product_price_current') }} c
