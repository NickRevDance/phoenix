{{ config(materialized = 'table') }}

with snap_versions as (

    select

          snap.*
        , row_number() over (
            partition by snap.product_price_entity_key
            order by snap.effective_start_datetime desc
          ) as snap_version
        -- 1 = the live list_price for this window. A window only gets
        -- more than one snap_version if D365 edited its AMOUNT in place
        -- (see the snapshot's own description) -- taking snap_version = 1
        -- means the gold grain stays exactly the declared business key
        -- (one row per product_key + price_type + price_currency_code +
        -- effective_date + source_system); an in-place-edited window's
        -- superseded amount is absorbed rather than emitted as its own
        -- row. If Nick wants in-place-edit history surfaced as its own
        -- rows later, that's a version_number column away -- flagged in
        -- the README, not implemented here since the spec's declared key
        -- has no room for it.

    from {{ ref('silver_snapshot_fact_product_price') }} snap

),

windows as (

    select * from snap_versions where snap_version = 1

),

sequenced as (

    select

          w.*

        , row_number() over (
            partition by w.product_key, w.price_type, w.price_currency_code
            order by w.effective_date desc, w.effective_start_datetime desc
          ) as recency_rank
        -- 1 = the most recent window in this variant + price_type +
        -- currency series. Business Rule 8.3: where the source carries
        -- two open windows for the same variant + currency (a DQ
        -- condition, not a real state), the one with the latest FROMDATE
        -- (then latest MODIFIEDDATE) is current and the other is
        -- Superseded -- recency_rank captures exactly that ordering, so
        -- the same rule that picks the current row also demotes the
        -- loser without a separate branch.

        , lag(w.list_price) over (
            partition by w.product_key, w.price_type, w.price_currency_code
            order by w.effective_date, w.effective_start_datetime
          ) as prior_price

    from windows w

),

final as (

    select

          xxhash64(
              s.product_id, s.d365_invent_dim_id, s.price_type,
              s.price_currency_code, cast(s.effective_date as string), s.source_system
          ) as product_price_key

        , s.product_key
        , s.product_id
        , s.sku
        , s.d365_invent_dim_id
        , s.source_system

        , s.price_type
        , cast(null as string) as price_subtype  -- Phase 2
        , cast(null as string) as price_list_id  -- Phase 2 -- no PriceDiscTable column confirmed as this identifier (DEFINITIONGROUP/PDSCALCULATIONID checked, both tenant-wide constants)

        , cast(null as bigint) as sales_channel_key  -- Phase 2
        , cast(null as string) as channel_code  -- Phase 2

        , s.effective_date
        -- Business Rule 8.2 / Field Catalog: a FROMDATE of 1900-01-01 is
        -- retained as the effective_date value itself but its date-key
        -- FK goes to -1 (410 such rows confirmed live 2026-09-15 -- spec
        -- text cites ten from the day before profiling; see README).
        , case
            when s.effective_date = date('1900-01-01') then -1
            else cast(date_format(s.effective_date, 'yyyyMMdd') as int)
          end as effective_date_key
        , s.expiration_date
        , cast(null as date) as promo_start_date  -- Phase 2, SALE/PROMO only
        , cast(null as date) as promo_end_date  -- Phase 2, SALE/PROMO only
        , s.d365_price_update_datetime

        , s.list_price
        , cast(null as decimal(19,4)) as sale_price  -- Phase 2 -- PriceDiscTable has no promotional records (spec Section 2/Open Decision #6), needs BigCommerce
        , cast(null as decimal(19,4)) as msrp  -- Open Decision #2, closed: not maintained, no source in D365 or PLM
        , cast(null as decimal(19,4)) as b2b_price  -- Phase 2, Open Decision #5 (winning-agreement rule not yet decided)
        , cast(null as decimal(19,4)) as minimum_advertised_price  -- Phase 3, no source identified

        , cast(null as decimal(19,4)) as discount_amount  -- Phase 2, derived only from a current SALE/PROMO row per spec 8.5
        , cast(null as decimal(9,4)) as discount_pct  -- Phase 2

        , cast(null as decimal(18,4)) as price_break_qty  -- Phase 2, not a Phase 1 concern (2 live volume-tier rows total)
        , cast(null as string) as price_break_tier  -- Phase 2

        , s.price_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd  -- Phase 2
        -- NOTE: this is the FX-normalized cross-currency column (Field
        -- Catalog Currency section), distinct from V_PRODUCT_PRICE_CURRENT's
        -- like-named list_price_usd/list_price_cad, which pivot the
        -- native-currency price rather than convert it (spec Section 4.4).
        , cast(null as decimal(19,4)) as list_price_usd  -- Phase 2
        , cast(null as decimal(19,4)) as sale_price_usd  -- Phase 2

        , case when s.recency_rank = 1 and s.expiration_date is null then true else false end as is_current
        -- Field Catalog price_status: Active (the winning open window),
        -- Superseded (a closed window with a later window in the same
        -- series -- or an open window that lost the DQ tie-break above),
        -- Expired (a closed window with no later window at all -- the
        -- variant has no standing price in that currency anymore).
        , case
            when s.recency_rank = 1 and s.expiration_date is null then 'Active'
            when s.recency_rank = 1 and s.expiration_date is not null then 'Expired'
            else 'Superseded'
          end as price_status

        , cast(null as boolean) as is_on_sale_flag  -- Phase 2, set on the LIST row when a current SALE/PROMO row exists for the same variant + currency

        , s.d365_trade_agreement_id
        , s.d365_price_group
        , cast(null as string) as bigcommerce_price_id  -- Phase 2, no BigCommerce pricing entity ingested yet

        , s.prior_price
        , s.list_price - s.prior_price as price_change_amount
        , case
            when s.prior_price is null or s.prior_price = 0 then null
            else (s.list_price - s.prior_price) / s.prior_price * 100
          end as price_change_pct
        , cast(null as string) as price_change_reason  -- Phase 2

        , 'silver_snapshot_fact_product_price' as record_source_table
        , s.effective_start_datetime as etl_insert_datetime
        , s.etl_update_datetime
        , s.row_hash

    from sequenced s

)

select * from final
