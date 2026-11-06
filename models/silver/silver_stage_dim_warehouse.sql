-- EDW-90: stage for silver_snapshot_dim_warehouse. warehouse_change_hash covers every Type 2
-- attribute in the spec's tracking plan, including the ones still typed NULL, so populating
-- them later versions only the warehouses that change and needs no snapshot reset.

with warehouse_base as (

    select

          l.INVENTLOCATIONID                     as warehouse_id
        , 'D365'                                  as source_system
        , l.NAME                                  as warehouse_name
        , cast(l.INVENTLOCATIONTYPE as string)    as d365_location_type
        , l.INVENTLOCATIONID                      as d365_warehouse_id
        , s.SITEID                                as d365_site_id
        , l.INVENTLOCATIONTYPE in (1, 2, 10, 11)  as is_virtual  -- Quarantine, Transit, Goods in Transit, Under-Delivery

    from {{ ref('silver_d365_inventory_location') }} l
    left join {{ ref('silver_d365_inventory_site') }} s
        on l.INVENTSITEID = s.SITEID

),

warehouse_attributes as (

    select

          {{ generate_surrogate_key(['b.warehouse_id', 'b.source_system']) }} as warehouse_key

        , b.warehouse_id
        , b.source_system
        , b.warehouse_name
        , cast(null as string) as warehouse_short_name  -- Source once available: no source identified in the spec
        , cast(null as string) as warehouse_description  -- Source once available: no source identified in the spec

        , case when b.is_virtual then 'Virtual' end as warehouse_type  -- NULL for location type 0 until REF_WAREHOUSE_TYPE_OVERRIDE (spec Open Decision 1)
        , cast(null as string) as warehouse_subtype  -- Source once available: Phase 2 classification
        , cast(null as int) as fulfillment_priority  -- Source once available: Phase 2 allocation rule

        , case when b.is_virtual then 0 else 1 end as is_fulfillment_enabled
        , case when b.is_virtual then 0 else 1 end as is_receiving_enabled
        , cast(null as boolean) as is_transfer_enabled  -- Source once available: Ops validation, Phase 2
        , cast(null as boolean) as is_returns_enabled  -- Source once available: Ops validation, Phase 2

        , cast(null as string) as address_line_1  -- Source once available: D365 logistics address chain, Phase 2
        , cast(null as string) as address_line_2  -- Source once available: D365 logistics address chain, Phase 2
        , cast(null as string) as city  -- Source once available: D365 logistics address chain, Phase 2
        , cast(null as string) as state_province  -- Source once available: D365 logistics address chain, Phase 2
        , cast(null as string) as postal_code  -- Source once available: D365 logistics address chain, Phase 2
        , cast(null as string) as country_code  -- Source once available: LogisticsPostalAddress.COUNTRYREGIONID, Phase 2
        , cast(null as bigint) as country_key  -- Source once available: DIM_COUNTRY (spec Open Decision 3)
        , cast(null as string) as geo_region  -- Source once available: region mapping off state/country, Phase 2
        , cast(null as decimal(10,7)) as latitude  -- Source once available: D365 logistics address chain, Phase 2
        , cast(null as decimal(10,7)) as longitude  -- Source once available: D365 logistics address chain, Phase 2
        , cast(null as string) as timezone  -- Source once available: manual seed; InventSite.TIMEZONE is an undecoded enum

        , cast(null as string) as operating_hours_start  -- spec type time, string in Databricks -- Source once available: Phase 3
        , cast(null as string) as operating_hours_end  -- spec type time, string in Databricks -- Source once available: Phase 3
        , cast(null as string) as order_cutoff_time  -- spec type time, string in Databricks -- Source once available: Phase 3
        , cast(null as decimal(18,2)) as capacity_sqft  -- Source once available: Phase 3
        , cast(null as int) as storage_capacity_units  -- Source once available: Phase 3
        , cast(null as string) as operator_name  -- Source once available: Phase 3
        , cast(null as string) as wms_system  -- Source once available: Phase 3

        , b.d365_site_id
        , b.d365_warehouse_id
        , b.d365_location_type

        , 'Active' as warehouse_status  -- every sourced warehouse; D365 has no warehouse status (spec v1.3 Section 9)
        , 1 as active_flag
        , cast(null as date) as effective_open_date  -- Source once available: no source identified
        , cast(null as date) as effective_close_date  -- Source once available: no source identified

        , 'silver_d365_inventory_location + silver_d365_inventory_site' as record_source_table

    from warehouse_base b

),

final as (

    select

          a.*

        -- this key is used to identify the fields used in SCD2. If more fields need to be tracked they should be added to this list.
        , {{ generate_row_hash([
              "coalesce(a.warehouse_name, '')",
              "coalesce(a.warehouse_type, '')",
              "coalesce(a.warehouse_subtype, '')",
              "coalesce(cast(a.fulfillment_priority as string), '')",
              "coalesce(cast(a.is_fulfillment_enabled as string), '')",
              "coalesce(cast(a.is_receiving_enabled as string), '')",
              "coalesce(a.address_line_1, '')",
              "coalesce(a.city, '')",
              "coalesce(a.state_province, '')",
              "coalesce(a.country_code, '')",
              "coalesce(a.order_cutoff_time, '')",
              "coalesce(cast(a.capacity_sqft as string), '')",
              "coalesce(cast(a.storage_capacity_units as string), '')",
              "coalesce(a.operator_name, '')",
              "coalesce(a.warehouse_status, '')",
              "coalesce(cast(a.active_flag as string), '')"
          ]) }} as warehouse_change_hash

        , current_timestamp() as etl_insert_datetime

    from warehouse_attributes a

)

select * from final
