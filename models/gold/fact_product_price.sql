{{ config(materialized = 'table') }}

with versioned as (

    select

          snap.*
        , row_number() over (
            partition by snap.product_price_entity_key
            order by snap.effective_start_datetime desc
          ) as version_number

        , case snap.price_type
            when 'LIST' then snap.list_price
            when 'SALE' then snap.sale_price
            when 'MSRP' then snap.msrp
            when 'B2B' then snap.b2b_price
          end as price_value

    from {{ ref('silver_snapshot_fact_product_price') }} snap

),

with_list_lookup as (

    select

          v.*
        , max(case when v.price_type = 'LIST' and v.version_number = 1 then v.price_value end) over (
            partition by v.product_id, v.source_system
          ) as current_list_price
        , max(case when v.price_type = 'SALE' and v.version_number = 1 then 1 else 0 end) over (
            partition by v.product_id, v.source_system
          ) as has_current_sale

    from versioned v

),

final as (

    select

          xxhash64(v.product_id, v.price_type, v.source_system, cast(v.effective_date as string)) as product_price_key

        , v.product_key
        , v.product_id
        , v.sku
        , v.source_system

        , v.price_type
        , v.price_subtype
        , v.price_list_id

        , cast(null as bigint) as sales_channel_key  -- Phase 2 -- Phase 1 assumes a single price per product across all channels
        , cast(null as string) as channel_code  -- Phase 2

        , v.effective_date
        , cast(date_format(v.effective_date, 'yyyyMMdd') as int) as effective_date_key
        , cast(v.effective_end_datetime as date) as expiration_date
        , cast(null as date) as promo_start_date  -- Phase 2 -- source data (PriceDiscTable.TODATE) already informs SALE row selection in silver, not persisted here per the project's phase-tag convention
        , cast(null as date) as promo_end_date  -- Phase 2, same note
        , v.d365_price_update_datetime

        , v.list_price
        , v.sale_price
        , v.msrp
        , v.b2b_price
        , cast(null as decimal(19,4)) as minimum_advertised_price  -- Phase 2

        , case
            when v.price_type = 'SALE' and v.version_number = 1 and v.current_list_price is not null
              then v.current_list_price - v.sale_price
          end as discount_amount
        , case
            when v.price_type = 'SALE' and v.version_number = 1 and v.current_list_price is not null and v.current_list_price <> 0
              then (v.current_list_price - v.sale_price) / v.current_list_price * 100
          end as discount_pct

        , cast(null as decimal(18,4)) as price_break_qty  -- Phase 2
        , cast(null as string) as price_break_tier  -- Phase 2

        , v.price_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd  -- Phase 2
        , cast(null as decimal(19,4)) as list_price_usd  -- Phase 2
        , cast(null as decimal(19,4)) as sale_price_usd  -- Phase 2

        , case when v.version_number = 1 then cast(1 as boolean) else cast(0 as boolean) end as is_current
        , case when v.version_number = 1 then 'Active' else 'Superseded' end as price_status  -- no 'Expired' state yet -- needs promo_end_date (Phase 2) to detect a closed promo window on a row that's otherwise still current

        , case when v.price_type = 'LIST' then cast(v.has_current_sale as boolean) end as is_on_sale_flag  -- spec sets this on the LIST row specifically -- null on non-LIST rows rather than broadcasting it to every price_type

        , v.d365_trade_agreement_id
        , v.d365_price_group
        , cast(null as string) as bigcommerce_price_id  -- Phase 2 -- no BigCommerce price source wired into this project yet

        , lag(v.price_value) over (
            partition by v.product_price_entity_key
            order by v.effective_start_datetime
          ) as prior_price
        , v.price_value - lag(v.price_value) over (
            partition by v.product_price_entity_key
            order by v.effective_start_datetime
          ) as price_change_amount
        , case
            when lag(v.price_value) over (
                   partition by v.product_price_entity_key
                   order by v.effective_start_datetime
                 ) is null
              or lag(v.price_value) over (
                   partition by v.product_price_entity_key
                   order by v.effective_start_datetime
                 ) = 0
            then null
            else (v.price_value - lag(v.price_value) over (
                    partition by v.product_price_entity_key
                    order by v.effective_start_datetime
                  )) / lag(v.price_value) over (
                    partition by v.product_price_entity_key
                    order by v.effective_start_datetime
                  ) * 100
          end as price_change_pct
        , cast(null as string) as price_change_reason  -- Phase 2

        , v.record_source_table
        , v.effective_start_datetime as etl_insert_datetime
        , v.etl_update_datetime
        , v.row_hash

    from with_list_lookup v

)

select * from final
