{{ config(materialized = 'table') }}

with sales_channel_base as (

    select

          s.channel_code
        , s.channel_name
        , s.channel_short_name
        , s.storefront_code
        , s.storefront_platform
        , s.is_loyalty_eligible
        , s.is_promotion_eligible
        , s.is_returns_enabled
        , s.channel_status
        , s.sort_order

    from {{ ref('silver_stage_dim_sales_channel') }} s

),

final as (

    select

        -- Surrogate PK: derived only from the business key (channel_code).
          xxhash64(b.channel_code) as sales_channel_key

        , b.channel_code
        , 'Manual Seed' as source_system

        , b.channel_name
        , b.channel_short_name
        , cast(null as string) as channel_description  -- Source once available: manual seed -- no description supplied in the initial seed yet

        , case
            when startswith(b.channel_code, 'BC_')   then 'Ecommerce'
            when startswith(b.channel_code, 'CALL_') then 'Call Center'
            when startswith(b.channel_code, 'B2B_')  then 'B2B Direct'
            when b.channel_code = 'INTERNAL'         then 'Internal'
          end as channel_type  -- derived from channel_code prefix per spec Section 8
        , cast(null as string) as channel_subtype  -- Source once available: manual classification -- Phase 2 per spec

        , b.storefront_code
        , cast(null as string) as fulfillment_method  -- Source once available: manual classification -- Phase 2 per spec

        , cast(null as string) as storefront_url  -- Source once available: BigCommerce storefront config -- Phase 2 per spec
        , b.storefront_platform

        , case
            when b.channel_code in ('BC_US', 'BC_TT') then 'US'
            when b.channel_code = 'BC_CA'              then 'CA'
            else 'US'  -- CALL_CTR/B2B_DIRECT/INTERNAL default to US (most volume) per spec Section 8
          end as country_code
        , cast(null as bigint) as country_key  -- Source once available: lookup against DIM_COUNTRY once built -- DIM_COUNTRY doesn't exist in this project yet
        , case
            when b.channel_code in ('BC_US', 'BC_TT') then 'USD'
            when b.channel_code = 'BC_CA'              then 'CAD'
            else 'USD'
          end as currency_code

        , cast(null as string) as tax_provider  -- Source once available: Vertex tax config -- Phase 2 per spec
        , cast(null as string) as payment_gateway  -- Source once available: payment processor config -- Phase 2 per spec

        , b.is_loyalty_eligible
        , b.is_promotion_eligible
        , b.is_returns_enabled
        , cast(null as bigint) as default_warehouse_key  -- Source once available: lookup against DIM_WAREHOUSE -- Phase 2 per spec

        , b.channel_status
        , case when b.channel_status = 'Active' then 1 else 0 end as is_active_flag  -- derived from channel_status per spec Section 8
        , cast(null as date) as effective_start_date  -- Source once available: manual seed -- no channel-launch date supplied yet
        , cast(null as date) as effective_end_date  -- NULL = active; no deactivation-date source wired yet

        , b.sort_order
        , cast(null as string) as hex_color_code  -- Source once available: brand kit -- Phase 2 per spec

        , 'sales_channel' as record_source_table
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

    from sales_channel_base b

)

select * from final
