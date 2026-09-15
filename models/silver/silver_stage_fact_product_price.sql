{{ config(materialized = 'table') }}

-- v1.1 rebuild (EDW-20). Grain moves from product_id to product_key
-- (variant) + price_currency_code -- see spec v1.1 Section 3 and project
-- memory fact_product_price_spec_v1.1_rebuild_2026-09-15.md. Every source
-- FROMDATE/TODATE window is now its own row (native history, Business
-- Rule 8.2) instead of collapsing to one row per item. SALE is dropped
-- entirely -- PriceDiscTable carries no promotional records (see README).

WITH barcode_dedup AS (

    -- ITEMID + INVENTDIMID -> ITEMBARCODE (UPC), deduped to one row per
    -- item + inventory dimension. 91,885 of the Phase-1-eligible rows'
    -- (ITEMID, INVENTDIMID) pairs have more than one barcode record on
    -- Rev_InventItembarcodeStaging as of 2026-09-15 -- most recently
    -- modified wins, same tie-break convention used everywhere else in
    -- this project.
    SELECT

          ITEMID
        , INVENTDIMID
        , ITEMBARCODE
        , row_number() over (
            partition by ITEMID, INVENTDIMID
            order by MODIFIEDDATE desc
          ) as rn

    FROM {{ ref('silver_d365_item_barcode') }}

),

list_price_population AS (

    -- Business Rule 8.1: MODULE = 1 is already applied upstream in
    -- silver_d365_price_disc_table_sales. A Phase 1 row additionally
    -- requires ACCOUNTCODE = 2 (All customers -- excludes the 241
    -- ACCOUNTCODE = 1 customer-group rows, which are the Phase 2 B2B
    -- derivation input per Section 8.6), ITEMCODE = 0 (a specific item,
    -- not an item-group agreement), QUANTITYAMOUNTFROM = 0 (base tier --
    -- excludes the 2 live volume-break rows), and AMOUNT <> 0. 149,865
    -- qualifying rows confirmed live 2026-09-15 (spec's own profiling
    -- cited 149,872 the day before -- ordinary day-over-day drift, not a
    -- discrepancy worth chasing).
    SELECT

          p.ITEMRELATION as product_id
        , p.INVENTDIMID as d365_invent_dim_id
        -- Business Rule 8.1/10: CURRENCY loads as-is, no default. Blank
        -- never occurs in the live extract (confirmed 2026-09-15, 0 of
        -- 149,865 rows) -- if it ever does it should surface as a DQ
        -- exception, not silently become USD the way the v1.0 build did.
        -- See tests/currency_not_blank.sql.
        , p.CURRENCY as price_currency_code
        , cast(p.AMOUNT as decimal(19,4)) as list_price
        , cast(p.FROMDATE as date) as source_from_date
        , cast(p.TODATE as date) as source_to_date
        , p.MODIFIEDDATE as d365_price_update_datetime
        , nullif(p.AGREEMENT, '') as d365_trade_agreement_id
        , p.RECID

    FROM {{ ref('silver_d365_price_disc_table_sales') }} p
    WHERE p.ACCOUNTCODE = 2
        and p.ITEMCODE = 0
        and p.QUANTITYAMOUNTFROM = 0
        and p.AMOUNT <> 0

),

deduped AS (

    -- Confirmed live 2026-09-15: 3,370 of 149,865 Phase-1-eligible rows
    -- (2.3%) share the exact same product_id + d365_invent_dim_id +
    -- price_currency_code + FROMDATE as another row -- the extract
    -- carries more than one synced state for what is really one window
    -- (e.g. the same window's still-open state and its later-closed
    -- state both landed as separate rows with the same FROMDATE but
    -- different TODATE/MODIFIEDDATE/RECID). Without this dedupe,
    -- product_price_entity_key collides and the downstream snapshot
    -- would error on a non-unique key. Most-recently-modified wins
    -- (RECID desc breaks exact-timestamp ties), same convention as the
    -- barcode dedupe above.
    SELECT
          lp.*
        , row_number() over (
            partition by lp.product_id, lp.d365_invent_dim_id, lp.price_currency_code, lp.source_from_date
            order by lp.d365_price_update_datetime desc, lp.RECID desc
          ) as dedupe_rn

    FROM list_price_population lp

),

resolved AS (

    SELECT

          lp.*
        -- Barcode path (spec Open Decision #9, build's own choice of the
        -- two options offered): INVENTDIMID + ITEMRELATION resolve
        -- through the D365 inventory dimension to a UPC, hashed
        -- identically to DIM_PRODUCT's own product_key formula
        -- (md5(ifnull(upc,'0'))) so the two line up without a second
        -- lookup table. Falls back to '-1' (this project's Unknown-member
        -- convention) when no barcode record exists for the item +
        -- inventory dimension -- the row is kept, not dropped, and
        -- resolution is tracked via tests/product_key_resolution_rate
        -- reporting (see README for the observed rate).
        , case
            when bar.ITEMBARCODE is not null
              then md5(concat_ws('|', bar.ITEMBARCODE))
            else '-1'
          end as product_key

    FROM deduped lp
    LEFT JOIN barcode_dedup bar
        ON bar.ITEMID = lp.product_id
        and bar.INVENTDIMID = lp.d365_invent_dim_id
        and bar.rn = 1
    WHERE lp.dedupe_rn = 1

),

dim_product_lookup AS (

    SELECT
          product_key
        , sku
        , line_discount_group as d365_price_group
    FROM {{ ref('dim_product') }}
    WHERE version_number = 1

)

SELECT

      r.product_id
    , r.d365_invent_dim_id
    , r.product_key
    , d.sku
    , d.d365_price_group
    , 'D365' as source_system
    , 'LIST' as price_type
    , r.price_currency_code
    , r.source_from_date as effective_date

    -- Business Rule 8.2: expiration_date is only a real close when TODATE
    -- is populated and isn't the 1900-01-01 sentinel; either way (null or
    -- sentinel) the window reads as open.
    , case
        when r.source_to_date is not null and r.source_to_date <> date('1900-01-01')
          then r.source_to_date
      end as expiration_date

    , r.d365_price_update_datetime
    , r.list_price
    , r.d365_trade_agreement_id

    -- Business key: every source window is its own entity now (unlike
    -- the v1.0 build, where this key deliberately excluded effective_date
    -- to collapse history into one row per item). The snapshot layer
    -- keys on this same value -- see its yml for what that buys us.
    , md5(concat_ws('|',
          r.product_id, r.d365_invent_dim_id, 'LIST', r.price_currency_code,
          cast(r.source_from_date as string), 'D365'
      )) as product_price_entity_key

    -- Change hash: only list_price can change in place on an
    -- already-loaded window (D365 editing an open agreement's AMOUNT
    -- without a new FROMDATE) -- that in-place edit is the one thing the
    -- snapshot layer exists to catch (spec Section 3.2).
    , sha2(coalesce(cast(r.list_price as string), ''), 256) as price_change_hash

FROM resolved r
LEFT JOIN dim_product_lookup d
    ON d.product_key = r.product_key
