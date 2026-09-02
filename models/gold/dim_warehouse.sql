
with warehouse_base as (
 
    select
 
          l.INVENTLOCATIONID                     as warehouse_id
        , 'D365'                                  as source_system
        , l.NAME                                  as warehouse_name
        , cast(l.INVENTLOCATIONTYPE as string)    as d365_location_type
        , l.INVENTLOCATIONID                      as d365_warehouse_id
        , s.SITEID                                as d365_site_id
 
    from {{ ref('silver_d365_inventory_location') }} l
    left join {{ ref('silver_d365_inventory_site') }} s
        on l.INVENTSITEID = s.SITEID
 
),
 
final as (
 
    select
 
          xxhash64(b.warehouse_id, b.source_system) as warehouse_key
 
        , b.warehouse_id
        , b.source_system
        , b.warehouse_name
        , null warehouse_short_name  -- Source once available: no field identified in spec source mapping (section 10) -- Phase 1, no source yet
        , null warehouse_description -- Source once available: no field identified in spec source mapping (section 10) -- Phase 1, no source yet
 
        , case when b.d365_location_type in ('1', '2') then 'Virtual' end as warehouse_type -- 'Virtual' for Quarantine (1) / Transit (2) per spec section 9; null for code 0, which spans both Distribution Center and Drop Ship -- see header note, business rule TBD for that split
        , null warehouse_subtype     -- Source once available: manual classification -- Phase 2, same reference-table dependency as warehouse_type
        , null fulfillment_priority  -- Source once available: allocation-priority rule -- Phase 2, no source yet
 
        , case when b.d365_location_type in ('1', '2') then 0 else 1 end as is_fulfillment_enabled -- 0 for Quarantine (1) / Transit (2), else 1 (Phase 1 default) per spec section 9's literal Transit-or-Quarantine rule -- see header note on codes 10/11
        , case when b.d365_location_type in ('1', '2') then 0 else 1 end as is_receiving_enabled   -- same rule and caveat as is_fulfillment_enabled
        , null is_transfer_enabled    -- Source once available: no default rule or source column identified in spec -- Phase 1, no source yet
        , null is_returns_enabled     -- Source once available: no default rule or source column identified in spec -- Phase 1, no source yet
 
        , null address_line_1  -- Source once available: D365 logistics address chain (InventLocation -> InventLocationLogisticsLocation -> LogisticsLocation -> LogisticsPostalAddress) -- Phase 2, not yet ingested via BYOD
        , null address_line_2  -- Source once available: D365 logistics address chain -- Phase 2, not yet ingested via BYOD
        , null city             -- Source once available: D365 logistics address chain -- Phase 2, not yet ingested via BYOD
        , null state_province  -- Source once available: D365 logistics address chain -- Phase 2, not yet ingested via BYOD
        , null postal_code     -- Source once available: D365 logistics address chain -- Phase 2, not yet ingested via BYOD
        , null country_code    -- Source once available: D365 logistics address chain (LogisticsPostalAddress.CountryRegionId) -- Phase 2, not yet ingested via BYOD
        , null country_key     -- Source once available: lookup against DIM_COUNTRY once country_code is sourced -- DIM_COUNTRY doesn't exist in this project yet either
        , null geo_region      -- Source once available: derived from state_province/country_code region mapping -- Phase 2, blocked on country_code
 
        , null latitude   -- Source once available: D365 logistics address chain -- Phase 2, not yet ingested via BYOD
        , null longitude  -- Source once available: D365 logistics address chain -- Phase 2, not yet ingested via BYOD
        , null timezone   -- Source once available: manual seed/reference data -- not natively in D365 per spec section 10; bronze_byod_inventory_site.TIMEZONE is an undecoded D365 enum, not a usable IANA string
 
        , null operating_hours_start   -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file
        , null operating_hours_end     -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file
        , null order_cutoff_time       -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file
        , null capacity_sqft           -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file
        , null storage_capacity_units  -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file
        , null operator_name           -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file
        , null wms_system              -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file
 
        , b.d365_site_id
        , b.d365_warehouse_id
        , b.d365_location_type
 
        , 'Active' as warehouse_status -- Phase 1 default per spec section 9: D365 has no native warehouse status; REF_WAREHOUSE_STATUS_OVERRIDE for Inactive/Decommissioned/Planned doesn't exist yet
        , 1 as active_flag             -- derived per spec section 9: active_flag = 1 when warehouse_status = 'Active'
 
        , null effective_open_date   -- Source once available: no field identified in spec source mapping -- can't be derived from a single-extract select
        , null effective_close_date  -- Source once available: soft-close date once incremental/merge load logic exists (spec section 9) -- can't be derived from a single-extract select
 
        , cast(1 as boolean) as is_current_row     -- trivially true today -- becomes meaningful once SCD2 snapshot wiring lands
        , current_date() as version_start_date     -- initial load: treated as the first version for every warehouse
        , cast(null as date) as version_end_date   -- NULL = current row
        , 1 as version_number
        , 'Initial load' as scd_change_reason
 
        , 'silver_d365_inventory_location + silver_d365_inventory_site' as record_source_table
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime
 
        , sha2(
            concat_ws('||',
                coalesce(b.warehouse_name, ''),
                coalesce(case when b.d365_location_type in ('1', '2') then 'Virtual' end, ''),           -- warehouse_type
                coalesce(cast(case when b.d365_location_type in ('1', '2') then 0 else 1 end as string), ''), -- is_fulfillment_enabled
                coalesce(cast(case when b.d365_location_type in ('1', '2') then 0 else 1 end as string), ''), -- is_receiving_enabled
                coalesce('Active', ''),            -- warehouse_status (Phase 1 default)
                coalesce(cast(1 as string), '')   -- active_flag (derived from warehouse_status)
            ), 256
          ) as row_hash -- hashes the currently-populated Type 2 (history-tracked) attributes per the spec's SCD2 Tracking Plan (section 4); extend this list as null placeholders above get wired to real sources (warehouse_subtype, fulfillment_priority, address/city/state/country, order_cutoff_time, capacity_sqft/storage_capacity_units, operator_name)
 
    from warehouse_base b
 
)
 
select * from final