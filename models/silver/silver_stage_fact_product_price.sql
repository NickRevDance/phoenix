{{ config(materialized = 'table') }}

WITH dim_product_by_item AS (

    -- dim_product's real grain is product_key (UPC/colorway), many-to-one
    -- with product_id (the D365 item) -- dedupe to one row per product_id
    -- before joining, same pattern as silver_stage_fact_product_cost.
    SELECT

          product_id
        , product_key
        , sku
        , line_discount_group
        , row_number() over (partition by product_id order by product_key) as rn

    FROM {{ ref('dim_product') }}
    WHERE version_number = 1

),

list_price_current AS (

    -- LIST price: InventTableModule.Price (Module = Sales), the spec's
    -- recommended source, is a literal constant 0 across every row and
    -- every ModuleType in this warehouse (confirmed live 2026-09-10 --
    -- same dead-column finding as fact_product_cost's standard_cost_unit).
    -- Falls back to the same PriceDiscTable pattern used there: MODULE = 1
    -- (Sales trade agreements) rows with no customer account attached
    -- (149,872 of 150,113 MODULE=1 rows, 99.8%) are the generic/standing
    -- price population. Restricted to the base quantity tier
    -- (QUANTITYAMOUNTFROM = 0, excludes volume-break rows) with an
    -- open-ended validity window (no TODATE, or a sentinel/far-future one)
    -- to isolate a standing price from a time-bounded promotional one.
    -- NEEDS CONFIRMATION with Merchandising -- spec Open Decision #1.
    SELECT

          p.ITEMRELATION as product_id
        , cast(p.AMOUNT as decimal(19,4)) as price_amount
        , coalesce(nullif(p.CURRENCY, ''), 'USD') as price_currency_code
        , cast(p.FROMDATE as date) as effective_date
        , p.MODIFIEDDATE as d365_price_update_datetime
        , nullif(p.AGREEMENT, '') as d365_trade_agreement_id
        , row_number() over (
            partition by p.ITEMRELATION
            order by p.MODIFIEDDATE desc
          ) as rn

    FROM {{ ref('silver_d365_price_disc_table_sales') }} p
    WHERE p.AMOUNT <> 0
        and (p.ACCOUNTRELATION = '' or p.ACCOUNTRELATION is null)
        and p.QUANTITYAMOUNTFROM = 0
        and (p.TODATE is null or p.TODATE = date('1900-01-01') or p.TODATE >= date_add(current_date(), 400))
        and (p.FROMDATE is null or p.FROMDATE <= current_date())

),

sale_price_current AS (

    -- SALE price: same MODULE = 1 / no-account / base-tier population as
    -- LIST, but for rows carrying a real (non-sentinel) TODATE -- a
    -- defined promotional window, as opposed to LIST's open-ended rows.
    -- Deliberately not restricted to "currently active": the live data's
    -- most recent TODATE is 2026-08-18 (before this build date), so a
    -- currently-active-only filter returns zero rows -- this project's
    -- insert-only history pattern doesn't require the latest known record
    -- to still be in force today, same as every other price/cost type
    -- here. Operationalizes spec Open Decision #6's recommended option
    -- (b): detect sale prices by reading D365 PriceDiscTable promotional
    -- records directly. NEEDS CONFIRMATION with Nick/Globant.
    --
    -- CAUTION, confirmed live 2026-09-10: for the 1,400 items that get both
    -- a LIST and a SALE row from this split, the "SALE" price averages
    -- HIGHER than "LIST" (avg delta -$10.63/unit, i.e. -47%), the opposite
    -- of what a promotional markdown should look like. This means the
    -- open-ended-vs-bounded-TODATE heuristic may not actually be isolating
    -- promotional discounts -- it may instead be catching scheduled price
    -- increases or a different pricing hierarchy entirely. Do not treat
    -- discount_amount/discount_pct/is_on_sale_flag as trustworthy until
    -- Merchandising confirms this split is directionally correct.
    SELECT

          p.ITEMRELATION as product_id
        , cast(p.AMOUNT as decimal(19,4)) as price_amount
        , coalesce(nullif(p.CURRENCY, ''), 'USD') as price_currency_code
        , cast(p.FROMDATE as date) as effective_date
        , p.MODIFIEDDATE as d365_price_update_datetime
        , nullif(p.AGREEMENT, '') as d365_trade_agreement_id
        , row_number() over (
            partition by p.ITEMRELATION
            order by p.MODIFIEDDATE desc
          ) as rn

    FROM {{ ref('silver_d365_price_disc_table_sales') }} p
    WHERE p.AMOUNT <> 0
        and (p.ACCOUNTRELATION = '' or p.ACCOUNTRELATION is null)
        and p.QUANTITYAMOUNTFROM = 0
        and p.TODATE is not null
        and p.TODATE <> date('1900-01-01')
        and (p.FROMDATE is null or p.FROMDATE <= current_date())

),

-- NOTE: no B2B CTE in this build. MODULE = 1 rows WITH a customer account
-- attached (241 of 150,113 MODULE=1 rows, ~0.2%) exist, but every one has
-- AMOUNT = 0 -- confirmed live 2026-09-10. 219 of those 241 instead carry a
-- real, well-populated PERCENT1 discount (avg 12.7%), meaning these
-- customer-group trade agreements are percentage-off arrangements, not
-- fixed-dollar prices -- a b2b_price would need to be derived as
-- list_price * (1 - PERCENT1/100) or similar, which is a real modeling
-- decision (what base price, which agreement wins per item) that spec
-- Open Decision #5 leaves open. Not done unilaterally -- flagged for Nick.
-- No b2b_price rows are emitted until this is resolved (same convention
-- as fact_product_cost's original zero-source VENDOR cost_type).

list_price_rows AS (

    SELECT

          lp.product_id
        , 'D365' as source_system
        , 'LIST' as price_type
        , cast(null as string) as price_subtype  -- Phase 2
        , cast(null as string) as price_list_id  -- Source once available: no PriceDiscTable column confirmed as the price-list/trade-agreement-group id yet (candidates DEFINITIONGROUP/PDSCALCULATIONID/RELATION, none confirmed) -- NEEDS CONFIRMATION
        , lp.effective_date
        , lp.d365_price_update_datetime

        , lp.price_amount as list_price
        , cast(null as decimal(19,4)) as sale_price
        , cast(null as decimal(19,4)) as msrp  -- Source once available: no distinct MSRP field confirmed on D365/PLM -- spec Open Decision #2, unresolved
        , cast(null as decimal(19,4)) as b2b_price

        , lp.price_currency_code
        , lp.d365_trade_agreement_id
        , p.line_discount_group as d365_price_group
        , 'silver_d365_price_disc_table_sales' as record_source_table

        , p.product_key
        , p.sku

    FROM list_price_current lp
    LEFT JOIN dim_product_by_item p
        ON p.product_id = lp.product_id
        and p.rn = 1
    WHERE lp.rn = 1

),

sale_price_rows AS (

    SELECT

          sp.product_id
        , 'D365' as source_system
        , 'SALE' as price_type
        , cast(null as string) as price_subtype  -- Phase 2
        , cast(null as string) as price_list_id  -- see LIST row note

        , sp.effective_date
        , sp.d365_price_update_datetime

        , cast(null as decimal(19,4)) as list_price
        , sp.price_amount as sale_price
        , cast(null as decimal(19,4)) as msrp
        , cast(null as decimal(19,4)) as b2b_price

        , sp.price_currency_code
        , sp.d365_trade_agreement_id
        , p.line_discount_group as d365_price_group
        , 'silver_d365_price_disc_table_sales' as record_source_table

        , p.product_key
        , p.sku

    FROM sale_price_current sp
    LEFT JOIN dim_product_by_item p
        ON p.product_id = sp.product_id
        and p.rn = 1
    WHERE sp.rn = 1

),

combined AS (

    -- No b2b_price_rows branch -- see the NOTE above list_price_rows's
    -- sibling CTEs; b2b_price stays null on every row emitted here until
    -- a real dollar-basis B2B source is confirmed.
    SELECT * FROM list_price_rows
    UNION ALL
    SELECT * FROM sale_price_rows

)

SELECT
      c.*
    -- business key minus effective_date -- the SCD2 entity a new price record versions against
    , md5(concat_ws('|', c.product_id, c.price_type, c.source_system)) as product_price_entity_key
    -- change hash over every field that should trigger a new version when it changes
    , sha2(
        concat_ws('||',
            coalesce(cast(c.list_price as string), ''),
            coalesce(cast(c.sale_price as string), ''),
            coalesce(cast(c.msrp as string), ''),
            coalesce(cast(c.b2b_price as string), ''),
            coalesce(c.price_currency_code, ''),
            coalesce(c.d365_trade_agreement_id, ''),
            coalesce(c.d365_price_group, '')
        ), 256
      ) as price_change_hash
FROM combined c
