{{ config(materialized = 'table') }}

-- DIM_WAREHOUSE v1.3 (EDW-90): Type 2 attributes and SCD2 controls from silver_snapshot_dim_warehouse,
-- Type 1 attributes from the current silver_stage_dim_warehouse row (a warehouse that has left the
-- extract keeps them as last written). Facts resolve warehouse_key on version_number = 1;
-- is_current_row is the reporting filter.

with warehouse_versions as (

    select

          snap_w.warehouse_key
        , snap_w.warehouse_id
        , snap_w.source_system
        , snap_w.warehouse_name
        , case when stg.warehouse_key is not null then stg.warehouse_short_name else snap_w.warehouse_short_name end as warehouse_short_name
        , case when stg.warehouse_key is not null then stg.warehouse_description else snap_w.warehouse_description end as warehouse_description
        , snap_w.warehouse_type
        , snap_w.warehouse_subtype
        , snap_w.fulfillment_priority
        , snap_w.is_fulfillment_enabled
        , snap_w.is_receiving_enabled
        , case when stg.warehouse_key is not null then stg.is_transfer_enabled else snap_w.is_transfer_enabled end as is_transfer_enabled
        , case when stg.warehouse_key is not null then stg.is_returns_enabled else snap_w.is_returns_enabled end as is_returns_enabled
        , snap_w.address_line_1
        , case when stg.warehouse_key is not null then stg.address_line_2 else snap_w.address_line_2 end as address_line_2
        , snap_w.city
        , snap_w.state_province
        , case when stg.warehouse_key is not null then stg.postal_code else snap_w.postal_code end as postal_code
        , snap_w.country_code
        , case when stg.warehouse_key is not null then stg.country_key else snap_w.country_key end as country_key
        , case when stg.warehouse_key is not null then stg.geo_region else snap_w.geo_region end as geo_region
        , case when stg.warehouse_key is not null then stg.latitude else snap_w.latitude end as latitude
        , case when stg.warehouse_key is not null then stg.longitude else snap_w.longitude end as longitude
        , case when stg.warehouse_key is not null then stg.timezone else snap_w.timezone end as timezone
        , case when stg.warehouse_key is not null then stg.operating_hours_start else snap_w.operating_hours_start end as operating_hours_start
        , case when stg.warehouse_key is not null then stg.operating_hours_end else snap_w.operating_hours_end end as operating_hours_end
        , snap_w.order_cutoff_time
        , snap_w.capacity_sqft
        , snap_w.storage_capacity_units
        , snap_w.operator_name
        , case when stg.warehouse_key is not null then stg.wms_system else snap_w.wms_system end as wms_system
        , case when stg.warehouse_key is not null then stg.d365_site_id else snap_w.d365_site_id end as d365_site_id
        , case when stg.warehouse_key is not null then stg.d365_warehouse_id else snap_w.d365_warehouse_id end as d365_warehouse_id
        , case when stg.warehouse_key is not null then stg.d365_location_type else snap_w.d365_location_type end as d365_location_type
        , snap_w.warehouse_status
        , snap_w.active_flag
        , case when stg.warehouse_key is not null then stg.effective_open_date else snap_w.effective_open_date end as effective_open_date
        , case when stg.warehouse_key is not null then stg.effective_close_date else snap_w.effective_close_date end as effective_close_date
        , snap_w.effective_start_datetime
        , snap_w.effective_end_datetime
        , {{ scd2_version_number('snap_w.warehouse_key') }} as version_number
        , case
            when lag(snap_w.warehouse_change_hash) over w is null then 'Initial load'
            when lag(snap_w.warehouse_change_hash) over w = snap_w.warehouse_change_hash then 'Returned to source'
            else coalesce(nullif(concat_ws(', '
                , case when not (snap_w.warehouse_name <=> lag(snap_w.warehouse_name) over w) then 'warehouse_name' end
                , case when not (snap_w.warehouse_type <=> lag(snap_w.warehouse_type) over w) then 'warehouse_type' end
                , case when not (snap_w.warehouse_subtype <=> lag(snap_w.warehouse_subtype) over w) then 'warehouse_subtype' end
                , case when not (snap_w.fulfillment_priority <=> lag(snap_w.fulfillment_priority) over w) then 'fulfillment_priority' end
                , case when not (snap_w.is_fulfillment_enabled <=> lag(snap_w.is_fulfillment_enabled) over w) then 'is_fulfillment_enabled' end
                , case when not (snap_w.is_receiving_enabled <=> lag(snap_w.is_receiving_enabled) over w) then 'is_receiving_enabled' end
                , case when not (snap_w.address_line_1 <=> lag(snap_w.address_line_1) over w) then 'address_line_1' end
                , case when not (snap_w.city <=> lag(snap_w.city) over w) then 'city' end
                , case when not (snap_w.state_province <=> lag(snap_w.state_province) over w) then 'state_province' end
                , case when not (snap_w.country_code <=> lag(snap_w.country_code) over w) then 'country_code' end
                , case when not (snap_w.order_cutoff_time <=> lag(snap_w.order_cutoff_time) over w) then 'order_cutoff_time' end
                , case when not (snap_w.capacity_sqft <=> lag(snap_w.capacity_sqft) over w) then 'capacity_sqft' end
                , case when not (snap_w.storage_capacity_units <=> lag(snap_w.storage_capacity_units) over w) then 'storage_capacity_units' end
                , case when not (snap_w.operator_name <=> lag(snap_w.operator_name) over w) then 'operator_name' end
                , case when not (snap_w.warehouse_status <=> lag(snap_w.warehouse_status) over w) then 'warehouse_status' end
                , case when not (snap_w.active_flag <=> lag(snap_w.active_flag) over w) then 'active_flag' end
              ), ''), 'Tracked attribute change')
          end as scd_change_reason
        , snap_w.record_source_table
        , snap_w.etl_insert_datetime
        , snap_w.etl_update_datetime
        , snap_w.warehouse_change_hash
        , snap_w.row_hash

    from {{ ref('silver_snapshot_dim_warehouse') }} snap_w
    left join {{ ref('silver_stage_dim_warehouse') }} stg
        on snap_w.warehouse_id = stg.warehouse_id
        and snap_w.source_system = stg.source_system

    window w as (partition by snap_w.warehouse_key order by snap_w.effective_start_datetime)

),

reserved_members as (

    -- Spec Section 3.7: -1 unknown member, a literal outside the hash range. 0 (NO_WAREHOUSE) stays reserved, not built (Open Decision 6).
    select
          cast({{ unknown_member_key() }} as bigint)   as warehouse_key
        , 'UNKNOWN'                                    as warehouse_id
        , 'Manual Seed'                                as source_system
        , 'Unknown Warehouse'                          as warehouse_name
        , 'Unknown'                                    as warehouse_short_name
        , cast(null as string)                         as warehouse_description
        , 'Reserved'                                   as warehouse_type
        , cast(null as string)                         as warehouse_subtype
        , cast(null as int)                            as fulfillment_priority
        , 0                                            as is_fulfillment_enabled
        , 0                                            as is_receiving_enabled
        , cast(null as boolean)                        as is_transfer_enabled
        , cast(null as boolean)                        as is_returns_enabled
        , cast(null as string)                         as address_line_1
        , cast(null as string)                         as address_line_2
        , cast(null as string)                         as city
        , cast(null as string)                         as state_province
        , cast(null as string)                         as postal_code
        , cast(null as string)                         as country_code
        , cast(null as bigint)                         as country_key
        , cast(null as string)                         as geo_region
        , cast(null as decimal(10,7))                  as latitude
        , cast(null as decimal(10,7))                  as longitude
        , cast(null as string)                         as timezone
        , cast(null as string)                         as operating_hours_start
        , cast(null as string)                         as operating_hours_end
        , cast(null as string)                         as order_cutoff_time
        , cast(null as decimal(18,2))                  as capacity_sqft
        , cast(null as int)                            as storage_capacity_units
        , cast(null as string)                         as operator_name
        , cast(null as string)                         as wms_system
        , cast(null as string)                         as d365_site_id
        , cast(null as string)                         as d365_warehouse_id
        , cast(null as string)                         as d365_location_type
        , 'Active'                                     as warehouse_status
        , 1                                            as active_flag
        , cast(null as date)                           as effective_open_date
        , cast(null as date)                           as effective_close_date
        , cast(null as timestamp)                      as effective_start_datetime
        , cast(null as timestamp)                      as effective_end_datetime
        , 1                                            as version_number
        , 'Reserved member'                            as scd_change_reason
        , 'Manual Seed'                                as record_source_table
        , current_timestamp()                          as etl_insert_datetime
        , current_timestamp()                          as etl_update_datetime
        , 'Reserved member -- not derived from a hash.' as warehouse_change_hash
        , 'RESERVED'                                   as row_hash

),

unioned as (

    select * from warehouse_versions
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
