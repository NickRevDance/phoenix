{{ config(materialized = 'table') }}

with business_vendors as (

    select

          snap_v.vendor_key
        , snap_v.vendor_id
        , snap_v.source_system
        , snap_v.vendor_name
        , snap_v.vendor_short_name
        , snap_v.vendor_type
        , snap_v.vendor_subtype
        , snap_v.vendor_group
        , snap_v.vendor_category
        , snap_v.primary_contact_name
        , snap_v.primary_contact_email
        , snap_v.primary_contact_phone
        , snap_v.vendor_website
        , snap_v.address_line_1
        , snap_v.address_line_2
        , snap_v.city
        , snap_v.state_province
        , snap_v.postal_code
        , snap_v.country_code
        , snap_v.country_key
        , snap_v.geo_region
        , snap_v.payment_terms
        , snap_v.default_currency_code
        , snap_v.default_incoterm_code
        , snap_v.tax_id
        , snap_v.credit_limit
        , snap_v.default_lead_time_days
        , snap_v.quality_rating
        , snap_v.on_time_delivery_target_pct
        , snap_v.is_preferred_vendor
        , snap_v.compliance_status
        , snap_v.compliance_expiry_date
        , snap_v.country_of_origin_primary
        , snap_v.vendor_status
        , snap_v.active_flag
        , snap_v.effective_start_date
        , snap_v.effective_end_date
        , snap_v.d365_vendor_account
        , snap_v.d365_vendor_group_id
        , snap_v.d365_party_number
        , snap_v.record_source_table
        , snap_v.vendor_change_hash
        , snap_v.etl_insert_datetime
        , snap_v.effective_start_datetime
        , snap_v.effective_end_datetime
        , snap_v.row_hash
        , snap_v.etl_update_datetime
        , {{ scd2_version_number('snap_v.vendor_key') }} as version_number

    from {{ ref('silver_snapshot_dim_vendor') }} snap_v

),

reserved_members as (

    -- Hardcoded, not derived: xxhash64 can't produce -1/0 (the specific
    -- blocker raised on the EDW-25 sign-off review), so these two rows
    -- never flow through the silver -> snapshot -> xxhash64 pipeline
    -- above. Column list/order is matched explicitly (by name) to
    -- business_vendors above rather than relying on snap_v.* -- mirrors
    -- the DIM_SALES_CHANNEL v1.1 (EDW-77) reserved-member precedent.
    -- NOTE: d365_party_number's real source type (DirPartyTable.PARTYNUMBER)
    -- wasn't confirmed when this was written -- if the union below throws a
    -- type-mismatch error, fix the cast here, it's isolated to this column.

    select
          cast({{ unknown_member_key() }} as bigint)   as vendor_key
        , 'UNKNOWN'                                    as vendor_id
        , 'Manual Seed'                                as source_system
        , 'Unknown Vendor'                             as vendor_name
        , 'Unknown'                                    as vendor_short_name
        , 'Reserved'                                   as vendor_type
        , cast(null as string)                         as vendor_subtype
        , cast(null as string)                         as vendor_group
        , 'Reserved'                                   as vendor_category
        , cast(null as string)                         as primary_contact_name
        , cast(null as string)                         as primary_contact_email
        , cast(null as string)                         as primary_contact_phone
        , cast(null as string)                         as vendor_website
        , cast(null as string)                         as address_line_1
        , cast(null as string)                         as address_line_2
        , cast(null as string)                         as city
        , cast(null as string)                         as state_province
        , cast(null as string)                         as postal_code
        , cast(null as string)                         as country_code
        , cast(null as bigint)                         as country_key
        , cast(null as string)                         as geo_region
        , cast(null as string)                         as payment_terms
        , cast(null as string)                         as default_currency_code
        , cast(null as string)                         as default_incoterm_code
        , cast(null as string)                         as tax_id
        , cast(null as decimal(19,4))                  as credit_limit
        , cast(null as int)                            as default_lead_time_days
        , cast(null as string)                         as quality_rating
        , cast(null as decimal(5,2))                   as on_time_delivery_target_pct
        , cast(null as boolean)                        as is_preferred_vendor
        , cast(null as string)                         as compliance_status
        , cast(null as date)                           as compliance_expiry_date
        , cast(null as string)                         as country_of_origin_primary
        , 'Active'                                     as vendor_status
        , 1                                            as active_flag
        , cast(null as date)                           as effective_start_date
        , cast(null as date)                           as effective_end_date
        , 'UNKNOWN'                                    as d365_vendor_account
        , cast(null as string)                         as d365_vendor_group_id
        , cast(null as string)                         as d365_party_number
        , 'Manual Seed'                                as record_source_table
        , 'Reserved member -- not derived from a hash.' as vendor_change_hash
        , current_timestamp()                          as etl_insert_datetime
        , cast(null as timestamp)                      as effective_start_datetime
        , cast(null as timestamp)                      as effective_end_datetime
        , 'RESERVED'                                   as row_hash
        , current_timestamp()                          as etl_update_datetime
        , 1                                            as version_number

    union all

    select
          cast({{ default_member_key() }} as bigint)   as vendor_key
        , 'NO_VENDOR'                                  as vendor_id
        , 'Manual Seed'                                as source_system
        , 'Not Applicable'                             as vendor_name
        , 'N/A'                                        as vendor_short_name
        , 'Reserved'                                   as vendor_type
        , cast(null as string)                         as vendor_subtype
        , cast(null as string)                         as vendor_group
        , 'Reserved'                                   as vendor_category
        , cast(null as string)                         as primary_contact_name
        , cast(null as string)                         as primary_contact_email
        , cast(null as string)                         as primary_contact_phone
        , cast(null as string)                         as vendor_website
        , cast(null as string)                         as address_line_1
        , cast(null as string)                         as address_line_2
        , cast(null as string)                         as city
        , cast(null as string)                         as state_province
        , cast(null as string)                         as postal_code
        , cast(null as string)                         as country_code
        , cast(null as bigint)                         as country_key
        , cast(null as string)                         as geo_region
        , cast(null as string)                         as payment_terms
        , cast(null as string)                         as default_currency_code
        , cast(null as string)                         as default_incoterm_code
        , cast(null as string)                         as tax_id
        , cast(null as decimal(19,4))                  as credit_limit
        , cast(null as int)                            as default_lead_time_days
        , cast(null as string)                         as quality_rating
        , cast(null as decimal(5,2))                   as on_time_delivery_target_pct
        , cast(null as boolean)                        as is_preferred_vendor
        , cast(null as string)                         as compliance_status
        , cast(null as date)                           as compliance_expiry_date
        , cast(null as string)                         as country_of_origin_primary
        , 'Active'                                     as vendor_status
        , 1                                            as active_flag
        , cast(null as date)                           as effective_start_date
        , cast(null as date)                           as effective_end_date
        , 'NO_VENDOR'                                  as d365_vendor_account
        , cast(null as string)                         as d365_vendor_group_id
        , cast(null as string)                         as d365_party_number
        , 'Manual Seed'                                as record_source_table
        , 'Reserved member -- not derived from a hash.' as vendor_change_hash
        , current_timestamp()                          as etl_insert_datetime
        , cast(null as timestamp)                      as effective_start_datetime
        , cast(null as timestamp)                      as effective_end_datetime
        , 'RESERVED'                                   as row_hash
        , current_timestamp()                          as etl_update_datetime
        , 1                                            as version_number

),

unioned as (

    select * from business_vendors
    union all
    select * from reserved_members

),

final as (

    select

          u.*
        , {{ scd2_is_current_row() }} as is_current_row

    from unioned u

)

select * from final
