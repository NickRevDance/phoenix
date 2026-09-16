with d365_contractual_pricing as (

    select
          'D365' as source_system
        , cast(null as string) as source_storefront_code
        , cast(p.RECID as string) as source_promotion_id
        , cast(p.RECID as string) as promotion_code  -- no separate human-readable code exists on PriceDiscTable trade agreement lines; RECID doubles as the traceable identifier
        , concat_ws(' - ', 'D365 Contractual Pricing', coalesce(nullif(trim(p.ACCOUNTRELATION), ''), 'ALL ACCOUNTS'), coalesce(nullif(trim(p.ITEMRELATION), ''), 'ALL ITEMS')) as promotion_name
        , cast(null as string) as promotion_description  -- Source once available: PriceDiscTable has no free-text description field
        , 'CONTRACTUAL_PRICING' as promotion_class
        , 'TRADE_AGREEMENT' as promotion_mechanism
        , case
            when p.PERCENT1 is not null and p.PERCENT1 != 0 then 'PERCENT'
            when p.AMOUNT is not null and p.AMOUNT != 0 then 'FIXED_AMOUNT'
            else 'FIXED_PRICE'
          end as discount_type_default  -- confirmed live 2026-09-16: 219 percent rows, 149,899 amount rows, 0 markup rows out of 150,145 MODULE=1 rows
        , {{ amount("case when p.PERCENT1 is not null and p.PERCENT1 != 0 then p.PERCENT1 when p.AMOUNT is not null and p.AMOUNT != 0 then p.AMOUNT else p.PRICEUNIT end") }} as discount_value
        , case when p.FROMDATE = date('1900-01-01') then cast(null as date) else cast(p.FROMDATE as date) end as promotion_start_date
        , case when p.TODATE = date('1900-01-01') then cast(null as date) else cast(p.TODATE as date) end as promotion_end_date
        , cast(null as boolean) as is_active_flag_placeholder  -- computed below once dates are resolved, see is_active_flag
        , 'Company' as funding_source_default  -- NEEDS CONFIRMATION: assumes trade agreements are company-funded customer pricing, not a vendor rebate -- override via promotion_enrichment if Finance says otherwise
        , cast(null as bigint) as vendor_key
        , cast(null as string) as promotion_group_code  -- Open Decision D4: pending Marketing-maintained rollup
        , 'silver_d365_price_disc_table_sales' as record_source

    from {{ ref('silver_d365_price_disc_table_sales') }} p

),

d365_contractual_pricing_final as (

    select
          d.source_system
        , d.source_storefront_code
        , d.source_promotion_id
        , d.promotion_code
        , d.promotion_name
        , d.promotion_description
        , d.promotion_class
        , d.promotion_mechanism
        , d.discount_type_default
        , d.discount_value
        , d.promotion_start_date
        , d.promotion_end_date
        , case
            when (d.promotion_end_date is null or d.promotion_end_date >= current_date())
             and (d.promotion_start_date is null or d.promotion_start_date <= current_date())
            then true else false
          end as is_active_flag
        , d.funding_source_default
        , d.vendor_key
        , d.promotion_group_code
        , d.record_source
    from d365_contractual_pricing d

),

manual_seed as (

    select
          'Manual Seed' as source_system
        , nullif(trim(m.source_storefront_code), '') as source_storefront_code
        , m.source_promotion_id
        , m.promotion_code
        , m.promotion_name
        , m.promotion_description
        , m.promotion_class
        , m.promotion_mechanism
        , m.discount_type_default
        , {{ amount('m.discount_value') }} as discount_value
        , cast(nullif(m.promotion_start_date, '') as date) as promotion_start_date
        , cast(nullif(m.promotion_end_date, '') as date) as promotion_end_date
        , cast(m.is_active_flag as boolean) as is_active_flag
        , m.funding_source_default
        , cast(m.vendor_key as bigint) as vendor_key
        , m.promotion_group_code
        , 'promotion_manual' as record_source

    from {{ ref('promotion_manual') }} m

),

-- BigCommerce promotions/coupons: EDW-33 Fivetran connector scope has not been
-- confirmed to include the Promotions/Coupons objects, and no such table
-- exists in the warehouse yet (bc.RevCashCoupons is a per-customer cash-coupon
-- balance ledger, not a promotion definition -- not a match). Not sourced this
-- pass; see README.md for the row-load path once EDW-33 lands.

unioned as (

    select * from d365_contractual_pricing_final
    union all
    select * from manual_seed

),

enriched as (

    select
          u.source_system
        , u.source_storefront_code
        , u.source_promotion_id
        , u.promotion_code
        , u.promotion_name
        , u.promotion_description
        , u.promotion_class
        , u.promotion_mechanism
        , u.discount_type_default
        , u.discount_value
        , u.promotion_start_date
        , u.promotion_end_date
        , u.is_active_flag
        , coalesce(e.funding_source_default_override, u.funding_source_default) as funding_source_default
        , coalesce(cast(e.vendor_key_override as bigint), u.vendor_key) as vendor_key
        , coalesce(e.promotion_group_code_override, u.promotion_group_code) as promotion_group_code
        , u.record_source

    from unioned u
    left join {{ ref('promotion_enrichment') }} e
        on e.source_system = u.source_system
       and coalesce(nullif(trim(e.source_storefront_code), ''), 'NA') = coalesce(u.source_storefront_code, 'NA')
       and e.source_promotion_id = u.source_promotion_id

),

final as (

    select
          e.*
        , concat_ws('|', e.source_system, coalesce(e.source_storefront_code, 'NA'), e.source_promotion_id) as promotion_business_key
        , {{ generate_row_hash([
              "coalesce(e.promotion_code, '')",
              "coalesce(e.promotion_name, '')",
              "coalesce(e.promotion_description, '')",
              "coalesce(e.promotion_class, '')",
              "coalesce(e.promotion_mechanism, '')",
              "coalesce(e.discount_type_default, '')",
              "coalesce(cast(e.discount_value as string), '')",
              "coalesce(cast(e.promotion_start_date as string), '')",
              "coalesce(cast(e.promotion_end_date as string), '')",
              "coalesce(cast(e.is_active_flag as string), '')",
              "coalesce(e.funding_source_default, '')",
              "coalesce(cast(e.vendor_key as string), '')",
              "coalesce(e.promotion_group_code, '')"
          ]) }} as promotion_change_hash
        , current_timestamp() as etl_insert_datetime

    from enriched e

)

select * from final
