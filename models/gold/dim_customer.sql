{{ config(materialized = 'table', schema = 'marketing_gold') }}

with segment_map as (

    select
          p.customer_key
        , s.customer_segment_key
    from {{ ref('silver_stage_customer_segment_profile') }} p
    inner join {{ ref('dim_customer_segment') }} s
        on p.customer_segment_id = s.customer_segment_id
       and s.is_current_row = 1

),

customer_versions as (

    -- Type 2 attributes and SCD2 controls come from the snapshot. Type 1
    -- attributes are read from the current stage row: the snapshot checks
    -- customer_change_hash only, so a Type 1 change never creates a snapshot
    -- row. A hard-deleted account has no stage row and keeps its last
    -- snapshot values.
    select

          snap_c.customer_key
        , snap_c.customer_id
        , snap_c.source_system
        , snap_c.d365_customer_id
        , snap_c.bc_customer_id
        , snap_c.sf_customer_id
        , snap_c.customer_code
        , case when stg.customer_key is not null then stg.customer_name else snap_c.customer_name end      as customer_name
        , case when stg.customer_key is not null then stg.first_name else snap_c.first_name end         as first_name
        , case when stg.customer_key is not null then stg.last_name else snap_c.last_name end          as last_name
        , case when stg.customer_key is not null then stg.company_name else snap_c.company_name end       as company_name
        , case when stg.customer_key is not null then stg.email_hash else snap_c.email_hash end         as email_hash
        , case when stg.customer_key is not null then stg.email_domain else snap_c.email_domain end       as email_domain
        , case when stg.customer_key is not null then stg.phone_primary else snap_c.phone_primary end      as phone_primary
        , snap_c.ship_to_address_line_1
        , snap_c.ship_to_address_line_2
        , snap_c.ship_to_city
        , snap_c.ship_to_state_province
        , snap_c.ship_to_postal_code
        , snap_c.ship_to_country_code
        , snap_c.ship_to_country_key
        , case when stg.customer_key is not null then stg.bill_to_address_line_1 else snap_c.bill_to_address_line_1 end as bill_to_address_line_1
        , case when stg.customer_key is not null then stg.bill_to_city else snap_c.bill_to_city end           as bill_to_city
        , case when stg.customer_key is not null then stg.bill_to_state_province else snap_c.bill_to_state_province end as bill_to_state_province
        , case when stg.customer_key is not null then stg.bill_to_postal_code else snap_c.bill_to_postal_code end    as bill_to_postal_code
        , case when stg.customer_key is not null then stg.bill_to_country_code else snap_c.bill_to_country_code end   as bill_to_country_code
        , snap_c.customer_type
        , snap_c.person_type_code
        , snap_c.person_type_desc
        , case when stg.customer_key is not null then stg.storefront_code else snap_c.storefront_code end    as storefront_code
        , snap_c.sales_channel_key
        , snap_c.is_dso_member_flag
        , snap_c.dso_membership_status
        , snap_c.is_loyalty_eligible_flag
        , snap_c.loyalty_exclusion_reason
        , snap_c.customer_status
        , snap_c.is_credit_hold_flag
        , snap_c.is_tax_exempt_flag
        , snap_c.tax_exempt_certificate
        , case when stg.customer_key is not null then stg.currency_code else snap_c.currency_code end      as currency_code
        , snap_c.payment_terms
        , snap_c.credit_limit_amount
        , snap_c.first_order_date
        , snap_c.most_recent_order_date
        , cast(snap_c.account_created_date as date) as account_created_date
        , snap_c.account_created_date_key
        , snap_c.geo_region
        , snap_c.geo_state_province
        , snap_c.geo_metro_area
        , snap_c.customer_change_hash
        , snap_c.record_source_table
        , snap_c.etl_insert_datetime
        , snap_c.row_hash
        , snap_c.etl_update_datetime
        , snap_c.effective_start_datetime
        , snap_c.effective_end_datetime
        , sm.customer_segment_key  -- Type 1 overwrite -- always current, per DIM_CUSTOMER_SEGMENT spec section 3.1
        , cast(null as string) as scd_change_reason  -- Source once available: no per-attribute diff computed yet -- matches DIM_VENDOR precedent
        , {{ scd2_version_number('snap_c.customer_key', 'snap_c.effective_start_datetime') }} as version_number

    from {{ ref('silver_snapshot_dim_customer') }} snap_c
    left join {{ ref('silver_stage_dim_customer') }} stg
        on snap_c.customer_key = stg.customer_key
    left join segment_map sm
        on snap_c.customer_key = sm.customer_key

),

unknown_member as (

    -- Hardcoded, not hashed: xxhash64 cannot land on -1. Facts coalesce
    -- headerless lines to this row (EDW-135 item 3, spec v1.3 section 9).
    select
          cast({{ unknown_member_key() }} as bigint)  as customer_key
        , 'UNKNOWN'                                   as customer_id
        , 'Manual Seed'                               as source_system
        , cast(null as string)                        as d365_customer_id
        , cast(null as string)                        as bc_customer_id
        , cast(null as string)                        as sf_customer_id
        , cast(null as string)                        as customer_code
        , 'Unknown'                                   as customer_name
        , cast(null as string)                        as first_name
        , cast(null as string)                        as last_name
        , cast(null as string)                        as company_name
        , cast(null as string)                        as email_hash
        , cast(null as string)                        as email_domain
        , cast(null as string)                        as phone_primary
        , cast(null as string)                        as ship_to_address_line_1
        , cast(null as string)                        as ship_to_address_line_2
        , cast(null as string)                        as ship_to_city
        , cast(null as string)                        as ship_to_state_province
        , cast(null as string)                        as ship_to_postal_code
        , cast(null as string)                        as ship_to_country_code
        , cast(null as bigint)                        as ship_to_country_key
        , cast(null as string)                        as bill_to_address_line_1
        , cast(null as string)                        as bill_to_city
        , cast(null as string)                        as bill_to_state_province
        , cast(null as string)                        as bill_to_postal_code
        , cast(null as string)                        as bill_to_country_code
        , 'Unknown'                                   as customer_type
        , cast(null as string)                        as person_type_code
        , cast(null as string)                        as person_type_desc
        , cast(null as string)                        as storefront_code
        , cast(null as bigint)                        as sales_channel_key
        , cast(null as boolean)                       as is_dso_member_flag
        , cast(null as string)                        as dso_membership_status
        , cast(null as boolean)                       as is_loyalty_eligible_flag
        , cast(null as string)                        as loyalty_exclusion_reason
        , 'Unknown'                                   as customer_status
        , cast(null as boolean)                       as is_credit_hold_flag
        , cast(null as boolean)                       as is_tax_exempt_flag
        , cast(null as string)                        as tax_exempt_certificate
        , cast(null as string)                        as currency_code
        , cast(null as string)                        as payment_terms
        , cast(null as decimal(19,4))                 as credit_limit_amount
        , cast(null as date)                          as first_order_date
        , cast(null as date)                          as most_recent_order_date
        , cast(null as date)                          as account_created_date
        , cast(null as int)                           as account_created_date_key
        , cast(null as string)                        as geo_region
        , cast(null as string)                        as geo_state_province
        , cast(null as string)                        as geo_metro_area
        , 'Reserved member -- not derived from a hash.' as customer_change_hash
        , 'Manual Seed'                               as record_source_table
        , current_timestamp()                         as etl_insert_datetime
        , 'RESERVED'                                  as row_hash
        , current_timestamp()                         as etl_update_datetime
        , cast(null as timestamp)                     as effective_start_datetime
        , cast(null as timestamp)                     as effective_end_datetime
        , cast(null as bigint)                        as customer_segment_key
        , cast(null as string)                        as scd_change_reason
        , 1                                           as version_number

),

unioned as (

    select * from customer_versions
    union all
    select * from unknown_member

)

select
      u.*
    , {{ scd2_is_current_row() }} as is_current_row

from unioned u
