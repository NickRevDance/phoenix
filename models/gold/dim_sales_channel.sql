{{ config(materialized = 'table') }}

with sales_channel_base as (

    select

          s.channel_code
        , s.channel_name
        , s.channel_short_name
        , s.channel_description
        , s.channel_subtype
        , s.storefront_code
        , s.storefront_platform
        , s.is_loyalty_redemption_channel
        , s.loyalty_redemption_start_date
        , s.is_promotion_eligible
        , s.is_returns_enabled
        , s.channel_status
        , s.channel_start_date
        , s.sort_order

    from {{ ref('silver_stage_dim_sales_channel') }} s

),

business_channels as (

    select

        -- Surrogate PK: derived only from the business key (channel_code).
          xxhash64(b.channel_code) as sales_channel_key

        , b.channel_code
        , 'Manual Seed' as source_system

        , b.channel_name
        , b.channel_short_name
        , b.channel_description

        , case
            when startswith(b.channel_code, 'BC_')     then 'Ecommerce'
            when startswith(b.channel_code, 'CALL_')   then 'Call Center'
            when startswith(b.channel_code, 'NIMBLY_') then 'B2B Direct'
            when startswith(b.channel_code, 'B2B_')    then 'B2B Direct'
            when b.channel_code = 'INTERNAL'           then 'Internal'
          end as channel_type  -- derived from channel_code prefix per spec Section 8 (v1.1 adds NIMBLY_* -> B2B Direct)
        , b.channel_subtype  -- seed-sourced per spec Section 6; S2C/S2S on the Nimbly rows only, NULL elsewhere

        , b.storefront_code
        , cast(null as string) as fulfillment_method  -- Source once available: manual classification -- Phase 2 per spec
        , cast(null as string) as storefront_url  -- Source once available: BigCommerce storefront config -- Phase 2 per spec
        , b.storefront_platform

        , case
            when b.channel_code = 'BC_CA' then 'CA'
            else 'US'  -- BC_US/BC_TT/CALL_CTR/NIMBLY_*/B2B_DIRECT/INTERNAL are all US per spec Section 8
          end as country_code
        , cast(null as bigint) as country_key  -- Source once available: lookup against DIM_COUNTRY once built -- DIM_COUNTRY doesn't exist in this project yet
        , case
            when b.channel_code = 'BC_CA' then 'CAD'
            else 'USD'
          end as currency_code

        , cast(null as string) as tax_provider  -- Source once available: Vertex tax config -- Phase 2 per spec
        , cast(null as string) as payment_gateway  -- Source once available: payment processor config -- Phase 2 per spec

        , b.is_loyalty_redemption_channel  -- v1.1: replaces retired is_loyalty_eligible. Online redemption only (BC_US/BC_CA); eligibility lives on DIM_CUSTOMER
        , b.loyalty_redemption_start_date  -- v1.1 new; 2026-08-18 on BC_US/BC_CA (Revolution Rewards launch), NULL elsewhere
        , b.is_promotion_eligible
        , b.is_returns_enabled
        , cast(null as bigint) as default_warehouse_key  -- Source once available: lookup against DIM_WAREHOUSE -- Phase 2 per spec

        , b.channel_status
        , cast(case when b.channel_status = 'Active' then 1 else 0 end as boolean) as is_active_flag  -- derived from channel_status per spec Section 8
        , b.channel_start_date  -- v1.1 renamed from effective_start_date (EDW-8 reserves effective_* for SCD2 control)
        , cast(null as date) as channel_end_date  -- v1.1 renamed from effective_end_date. NULL = active; no deactivation-date source wired yet

        , b.sort_order
        , cast(null as string) as hex_color_code  -- Source once available: brand kit -- Phase 2 per spec

        , 'sales_channel' as record_source  -- v1.1 renamed from record_source_table (project standard)
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

    from sales_channel_base b

),

reserved_members as (

    -- v1.1 new (spec Section 3.4). Hard-coded, not derived: xxhash64 cannot
    -- produce -1/0, so these two rows never flow through the seed -> silver
    -- -> xxhash64 pipeline above. Every eligibility flag is 0/false, both
    -- rows are channel_status = Active / is_active_flag = true, sort_order
    -- 990 and 999 respectively.

    select
          -1                    as sales_channel_key
        , 'UNKNOWN'              as channel_code
        , 'Manual Seed'          as source_system
        , 'Unknown Channel'      as channel_name
        , 'Unknown'              as channel_short_name
        , 'Reserved member for orders whose origin is blank or not in the crosswalk.' as channel_description
        , 'Reserved'             as channel_type
        , cast(null as string)   as channel_subtype
        , cast(null as string)   as storefront_code
        , cast(null as string)   as fulfillment_method
        , cast(null as string)   as storefront_url
        , cast(null as string)   as storefront_platform
        , cast(null as string)   as country_code
        , cast(null as bigint)   as country_key
        , cast(null as string)   as currency_code
        , cast(null as string)   as tax_provider
        , cast(null as string)   as payment_gateway
        , false                  as is_loyalty_redemption_channel
        , cast(null as date)     as loyalty_redemption_start_date
        , false                  as is_promotion_eligible
        , false                  as is_returns_enabled
        , cast(null as bigint)   as default_warehouse_key
        , 'Active'               as channel_status
        , true                   as is_active_flag
        , cast(null as date)     as channel_start_date
        , cast(null as date)     as channel_end_date
        , 990                    as sort_order
        , cast(null as string)   as hex_color_code
        , 'sales_channel'        as record_source
        , current_timestamp()    as etl_insert_datetime
        , current_timestamp()    as etl_update_datetime

    union all

    select
          0                      as sales_channel_key
        , 'NO_SALES_CHANNEL'     as channel_code
        , 'Manual Seed'          as source_system
        , 'Not Applicable'       as channel_name
        , 'N/A'                  as channel_short_name
        , 'Reserved member for rows where channel does not apply.' as channel_description
        , 'Reserved'             as channel_type
        , cast(null as string)   as channel_subtype
        , cast(null as string)   as storefront_code
        , cast(null as string)   as fulfillment_method
        , cast(null as string)   as storefront_url
        , cast(null as string)   as storefront_platform
        , cast(null as string)   as country_code
        , cast(null as bigint)   as country_key
        , cast(null as string)   as currency_code
        , cast(null as string)   as tax_provider
        , cast(null as string)   as payment_gateway
        , false                  as is_loyalty_redemption_channel
        , cast(null as date)     as loyalty_redemption_start_date
        , false                  as is_promotion_eligible
        , false                  as is_returns_enabled
        , cast(null as bigint)   as default_warehouse_key
        , 'Active'               as channel_status
        , true                   as is_active_flag
        , cast(null as date)     as channel_start_date
        , cast(null as date)     as channel_end_date
        , 999                    as sort_order
        , cast(null as string)   as hex_color_code
        , 'sales_channel'        as record_source
        , current_timestamp()    as etl_insert_datetime
        , current_timestamp()    as etl_update_datetime

),

unioned as (

    select * from business_channels
    union all
    select * from reserved_members

),

final as (

    select

        u.*

        , sha2(
            concat_ws('||',
                coalesce(u.channel_name, ''),
                coalesce(u.channel_short_name, ''),
                coalesce(u.channel_description, ''),
                coalesce(u.channel_type, ''),
                coalesce(u.channel_subtype, ''),
                coalesce(u.storefront_code, ''),
                coalesce(u.storefront_platform, ''),
                coalesce(u.country_code, ''),
                coalesce(u.currency_code, ''),
                coalesce(cast(u.is_loyalty_redemption_channel as string), ''),
                coalesce(cast(u.loyalty_redemption_start_date as string), ''),
                coalesce(cast(u.is_promotion_eligible as string), ''),
                coalesce(cast(u.is_returns_enabled as string), ''),
                coalesce(u.channel_status, ''),
                coalesce(cast(u.is_active_flag as string), ''),
                coalesce(cast(u.channel_start_date as string), ''),
                coalesce(cast(u.channel_end_date as string), ''),
                coalesce(cast(u.sort_order as string), '')
            ), 256
          ) as row_hash  -- v1.1 new. Spec calls this "EDW-8 shared audit macro" but no such macro exists in this project yet -- dim_warehouse/dim_vendor/dim_customer all inline this same sha2/concat_ws pattern per model rather than share one. Worth centralizing if EDW-8 wants a literal shared macro.

    from unioned u

)

select * from final
