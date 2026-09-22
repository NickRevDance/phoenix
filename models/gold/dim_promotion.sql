{{ config(materialized = 'table', schema = 'shared_gold') }}

with versioned as (

    select

          {{ generate_surrogate_key(['snap.source_system', "coalesce(snap.source_storefront_code, 'NA')", 'snap.source_promotion_id', 'snap.effective_start_datetime']) }} as promotion_key  -- version-distinct: spec gives each SCD2 version its own key

        , snap.source_system
        , snap.source_storefront_code
        , snap.source_promotion_id
        , snap.promotion_code
        , snap.promotion_name
        , snap.promotion_description
        , snap.promotion_class
        , snap.promotion_mechanism
        , snap.discount_type_default
        , snap.discount_value
        , snap.promotion_start_date
        , snap.promotion_end_date
        , snap.is_active_flag
        , snap.funding_source_default
        , snap.vendor_key
        , snap.promotion_group_code

        , snap.effective_start_datetime
        , snap.effective_end_datetime

        , {{ scd2_version_number(partition_by='snap.promotion_business_key') }} as version_number

        , snap.record_source
        , snap.row_hash
        , snap.etl_insert_datetime
        , snap.etl_update_datetime

    from {{ ref('silver_snapshot_dim_promotion') }} snap

),

versioned_final as (

    select
          v.*
        , {{ scd2_is_current_row() }} as is_current_row
    from versioned v

),

reserved_members as (

    -- Default members (0 = NO_PROMOTION, -1 = UNKNOWN), seed-driven per the
    -- ticket so they load via `dbt seed` ahead of any fact needing a strict
    -- FK relationship test. Keys are hardcoded literals, not hashed --
    -- xxhash64 cannot be coerced to land on -1/0 (see reserved_dimension_members.sql).

    select
          {{ unknown_member_key() }} as promotion_key
        , r.source_system
        , nullif(trim(r.source_storefront_code), '') as source_storefront_code
        , r.source_promotion_id
        , r.promotion_code
        , r.promotion_name
        , r.promotion_description
        , r.promotion_class
        , r.promotion_mechanism
        , r.discount_type_default
        , cast(r.discount_value as decimal(38,6)) as discount_value
        , cast(nullif(r.promotion_start_date, '') as date) as promotion_start_date
        , cast(nullif(r.promotion_end_date, '') as date) as promotion_end_date
        , cast(r.is_active_flag as boolean) as is_active_flag
        , r.funding_source_default
        , cast(r.vendor_key as bigint) as vendor_key
        , r.promotion_group_code
        , cast(null as timestamp) as effective_start_datetime
        , cast(null as timestamp) as effective_end_datetime
        , 1 as version_number
        , 'promotion_default_members' as record_source
        , cast(null as string) as row_hash
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime
        , 1 as is_current_row
    from {{ ref('promotion_default_members') }} r
    where r.source_promotion_id = 'UNKNOWN'

    union all

    select
          {{ default_member_key() }} as promotion_key
        , r.source_system
        , nullif(trim(r.source_storefront_code), '') as source_storefront_code
        , r.source_promotion_id
        , r.promotion_code
        , r.promotion_name
        , r.promotion_description
        , r.promotion_class
        , r.promotion_mechanism
        , r.discount_type_default
        , cast(r.discount_value as decimal(38,6)) as discount_value
        , cast(nullif(r.promotion_start_date, '') as date) as promotion_start_date
        , cast(nullif(r.promotion_end_date, '') as date) as promotion_end_date
        , cast(r.is_active_flag as boolean) as is_active_flag
        , r.funding_source_default
        , cast(r.vendor_key as bigint) as vendor_key
        , r.promotion_group_code
        , cast(null as timestamp) as effective_start_datetime
        , cast(null as timestamp) as effective_end_datetime
        , 1 as version_number
        , 'promotion_default_members' as record_source
        , cast(null as string) as row_hash
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime
        , 1 as is_current_row
    from {{ ref('promotion_default_members') }} r
    where r.source_promotion_id = 'NO_PROMOTION'

),

final as (

    select * from versioned_final
    union all
    select * from reserved_members

)

select * from final
