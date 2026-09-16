{{ config(materialized = 'table') }}

/*
    DIM_WAREHOUSE -- conformed gold-layer dimension for warehouse/fulfillment
    node identity, classification, and capability attributes, shared across
    every warehouse-related fact table (FACT_INVENTORY_SNAPSHOT_DAILY,
    FACT_INVENTORY_MOVEMENT, FACT_PURCHASE_ORDER, FACT_SHIPMENT,
    FACT_EMPLOYEE_HOURS, FACT_INVENTORY_QUALITY_CODE_COLOR_DAILY).

    Grain (per spec): one row per warehouse per SCD2 version, latest flagged
    is_current_row = 1. This build is the Phase 1 initial load: only one
    version exists per warehouse today, so every row is current. True SCD2
    versioning (a new row per warehouse_key when a Type 2 attribute changes)
    isn't implemented here -- it needs this model wired into a dbt snapshot,
    the same pattern DIM_PRODUCT uses (silver_snapshot_dim_product), once
    change history needs to be captured. row_hash is populated now so that
    future snapshot wiring has a ready-made change-detection column.

    EDW-8 (2026-09-16): surrogate-key and row-hash generation now go through
    the shared generate_surrogate_key() / generate_row_hash() macros
    (macros/generate_surrogate_key.sql, macros/generate_row_hash.sql)
    instead of inlining xxhash64/sha2 directly, matching dim_vendor.sql and
    dim_sales_channel.sql. Also re-pointed off the renamed d365-prefixed
    silver sources (silver_d365_inventory_location / silver_d365_inventory_site
    -- this model still had the pre-rename silver_byod_* names, which no
    longer resolve). SCD2 shape (version_start_date/version_end_date,
    is_current_row as boolean, version_number hardcoded to 1) is
    deliberately UNCHANGED -- migrating this to the real 4-stage snapshot
    pattern (scd2_version_number()/scd2_is_current_row()) is a separate,
    coordinated change: fact_inventory_movement.sql and
    fact_purchase_order.sql both filter on is_current_row = true (would need
    to become = 1), and fact_inventory_snapshot_daily.sql joins here with NO
    current-row filter at all today (safe only because there's one row per
    warehouse right now) -- not a same-turn change.

    Business key: warehouse_id + source_system. Surrogate key: warehouse_key
    (bigint, via generate_surrogate_key()/xxhash64 -- stable across future
    SCD2 versions since it's derived only from the business key, never from
    tracked attributes).
    Caveat: source_system is a constant 'D365' literal (spec field catalog:
    "Expected: D365"), and warehouse_id isn't scoped by DATAAREAID. If this
    D365 environment has more than one legal entity with overlapping
    INVENTLOCATIONID values, this business key would collide across
    entities -- spec overview says fewer than 20 active warehouses are
    expected, so this is likely a non-issue, but wasn't verified here.

    Sources, left-joined on the warehouse's D365 site:
      - D365 InventLocation <- {{ ref('silver_d365_inventory_location') }} l
      - D365 InventSite     <- {{ ref('silver_d365_inventory_site') }} s
        Join: l.INVENTSITEID = s.SITEID. Location drives the FROM (not site)
        so every warehouse gets a row even if its site record is missing.
        The prior version of this model drove off site instead, which risked
        phantom rows for sites with no location and silently dropped
        locations with no matching site -- fixed here.

    GAPS -- no bronze source exists yet for any of these, so the columns
    stay null with a note on the source once it lands (see also
    [[dbt_build_conventions]] known source gaps):
      - D365 logistics address chain (InventLocation ->
        InventLocationLogisticsLocation -> LogisticsLocation ->
        LogisticsPostalAddress) for all address_* fields, country_code,
        country_key, geo_region, latitude, longitude -- Phase 2 per spec.
      - DIM_COUNTRY doesn't exist in this project yet, so country_key has no
        table to look up against even once country_code is sourced.
      - Operational enrichment (operating_hours_*, order_cutoff_time,
        capacity_sqft, storage_capacity_units, operator_name, wms_system) --
        Phase 3 per spec, source TBD (spec section 11: may require a manual
        seed file if no LogisticsLocation extension fields carry this).
      - timezone -- spec section 10 says this isn't natively in D365 and
        needs manual seed/reference data. the site's TIMEZONE field is an
        undecoded D365 enum code, not an IANA string, so it isn't a usable
        source as-is.
      - warehouse_short_name, warehouse_description -- no field identified
        in the spec's source mapping (section 10).

    INVENTLOCATIONTYPE decode -- confirmed Full breakdown across all 18 active locations (silver_d365_inventory_location,
    grouped by INVENTLOCATIONTYPE):
      0  (6 rows): ChiBW, DropShip, KC 2Die4, KCMOBW, Niles, OakBW
      1  (1 row):  Niles-Q               -> Quarantine
      2  (5 rows): ChiBW-T, DropShip-T, KCMOBW-T, Niles-T, OakBW-T -> Transit
      10 (5 rows): ChiBW-GT, DropShip-G, KCMOBW-GT, Niles-GT, OakBW-GT
                   -> Goods-in-Transit
      11 (1 row):  Niles-UD              -> Under-Delivery
    Applied below: warehouse_type = 'Virtual' and is_fulfillment_enabled /
    is_receiving_enabled = 0 for codes 1 and 2 (Quarantine, Transit) per
    spec section 9's literal "Transit or Quarantine" rule. Codes 10 and 11
    (Goods-in-Transit, Under-Delivery) sound similarly non-fulfillment by
    name but aren't covered by that literal rule, so they still fall through
    to the "physical warehouses default to 1" catch-all and stay
    is_fulfillment_enabled/is_receiving_enabled = 1, warehouse_type = null --
    worth a follow-up with Nick on whether the spec's binary rule should
    have been a third bucket.

    warehouse_type otherwise stays null for code 0 even though it's the
    "physical" bucket: it covers both what look like Distribution Centers
    (Niles, ChiBW, KCMOBW, OakBW) and what's explicitly a different
    classification per the spec's own enum (DropShip -> 'Drop Ship'), so a
    single INVENTLOCATIONTYPE code can't resolve to one warehouse_type value
    -- this is exactly the "may require reference table" gap spec section 10
    flags; it isn't guessed here.
      - warehouse_subtype, fulfillment_priority -- Phase 2, same
        classification-reference dependency as warehouse_type.
      - is_transfer_enabled, is_returns_enabled -- spec section 9 only
        defines a Phase 1 default for is_fulfillment_enabled /
        is_receiving_enabled; no equivalent default rule is given for
        transfer/returns, and no source column exists.

    warehouse_status defaults to 'Active' for every row per spec section 9
    ("D365 has no native warehouse status... all sourced warehouses default
    to Active"). The REF_WAREHOUSE_STATUS_OVERRIDE reference table the spec
    describes for Inactive/Decommissioned/Planned doesn't exist yet, so no
    warehouse can currently resolve to anything but Active. active_flag is
    derived straight from warehouse_status per the spec's stated formula.

    NOT built here:
      - The soft-close behavior in spec section 9 ("warehouses that
        disappear from the BYOD extract are soft-closed... rather than
        deleted") -- this is a stateless select over the current extract, so
        it can't detect a warehouse that dropped out of a prior load. Needs
        incremental/merge logic once this table's load strategy is revisited.
      - effective_open_date / effective_close_date -- no field is identified
        in the spec's source mapping and neither can be derived from a
        single-extract select; both stay null.
      - REF_WAREHOUSE_STATUS_OVERRIDE lookup (see above).
      - V_DIM_WAREHOUSE_CURRENT companion view (spec section 8) -- not built
        as part of this change.
*/

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

          {{ generate_surrogate_key(['b.warehouse_id', 'b.source_system']) }} as warehouse_key

        , b.warehouse_id
        , b.source_system
        , b.warehouse_name
        , cast(null as string) as warehouse_short_name  -- Source once available: no field identified in spec source mapping (section 10) -- Phase 1, no source yet
        , cast(null as string) as warehouse_description  -- Source once available: no field identified in spec source mapping (section 10) -- Phase 1, no source yet

        , case when b.d365_location_type in ('1', '2') then 'Virtual' end as warehouse_type -- 'Virtual' for Quarantine (1) / Transit (2) per spec section 9; null for code 0, which spans both Distribution Center and Drop Ship -- see header note, business rule TBD for that split
        , cast(null as string) as warehouse_subtype  -- Source once available: manual classification -- Phase 2, same reference-table dependency as warehouse_type
        , cast(null as int) as fulfillment_priority  -- Source once available: allocation-priority rule -- Phase 2, no source yet

        , case when b.d365_location_type in ('1', '2') then 0 else 1 end as is_fulfillment_enabled -- 0 for Quarantine (1) / Transit (2), else 1 (Phase 1 default) per spec section 9's literal Transit-or-Quarantine rule -- see header note on codes 10/11
        , case when b.d365_location_type in ('1', '2') then 0 else 1 end as is_receiving_enabled   -- same rule and caveat as is_fulfillment_enabled
        , cast(null as boolean) as is_transfer_enabled  -- Source once available: no default rule or source column identified in spec -- Phase 1, no source yet
        , cast(null as boolean) as is_returns_enabled  -- Source once available: no default rule or source column identified in spec -- Phase 1, no source yet

        , cast(null as string) as address_line_1  -- Source once available: D365 logistics address chain (InventLocation -> InventLocationLogisticsLocation -> LogisticsLocation -> LogisticsPostalAddress) -- Phase 2, not yet ingested via BYOD
        , cast(null as string) as address_line_2  -- Source once available: D365 logistics address chain -- Phase 2, not yet ingested via BYOD
        , cast(null as string) as city  -- Source once available: D365 logistics address chain -- Phase 2, not yet ingested via BYOD
        , cast(null as string) as state_province  -- Source once available: D365 logistics address chain -- Phase 2, not yet ingested via BYOD
        , cast(null as string) as postal_code  -- Source once available: D365 logistics address chain -- Phase 2, not yet ingested via BYOD
        , cast(null as string) as country_code  -- Source once available: D365 logistics address chain (LogisticsPostalAddress.CountryRegionId) -- Phase 2, not yet ingested via BYOD
        , cast(null as bigint) as country_key  -- Source once available: lookup against DIM_COUNTRY once country_code is sourced -- DIM_COUNTRY doesn't exist in this project yet either
        , cast(null as string) as geo_region  -- Source once available: derived from state_province/country_code region mapping -- Phase 2, blocked on country_code

        , cast(null as decimal(10,7)) as latitude  -- Source once available: D365 logistics address chain -- Phase 2, not yet ingested via BYOD
        , cast(null as decimal(10,7)) as longitude  -- Source once available: D365 logistics address chain -- Phase 2, not yet ingested via BYOD
        , cast(null as string) as timezone  -- Source once available: manual seed/reference data -- not natively in D365 per spec section 10; the site's TIMEZONE field is an undecoded D365 enum, not a usable IANA string

        , cast(null as string) as operating_hours_start  -- spec type is `time`; Databricks has no native TIME type, cast as string instead -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file
        , cast(null as string) as operating_hours_end  -- spec type is `time`; Databricks has no native TIME type, cast as string instead -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file
        , cast(null as string) as order_cutoff_time  -- spec type is `time`; Databricks has no native TIME type, cast as string instead -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file
        , cast(null as decimal(18,2)) as capacity_sqft  -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file
        , cast(null as int) as storage_capacity_units  -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file
        , cast(null as string) as operator_name  -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file
        , cast(null as string) as wms_system  -- Source once available: operational enrichment source TBD -- Phase 3 per spec, may require manual seed file

        , b.d365_site_id
        , b.d365_warehouse_id
        , b.d365_location_type

        , 'Active' as warehouse_status -- Phase 1 default per spec section 9: D365 has no native warehouse status; REF_WAREHOUSE_STATUS_OVERRIDE for Inactive/Decommissioned/Planned doesn't exist yet
        , 1 as active_flag             -- derived per spec section 9: active_flag = 1 when warehouse_status = 'Active'

        , cast(null as date) as effective_open_date  -- Source once available: no field identified in spec source mapping -- can't be derived from a single-extract select
        , cast(null as date) as effective_close_date  -- Source once available: soft-close date once incremental/merge load logic exists (spec section 9) -- can't be derived from a single-extract select

        , cast(1 as boolean) as is_current_row     -- trivially true today -- becomes meaningful once SCD2 snapshot wiring lands (see EDW-8 note above: this is int-vs-boolean divergence from dim_product/dim_vendor, intentionally not migrated yet)
        , current_date() as version_start_date     -- initial load: treated as the first version for every warehouse
        , cast(null as date) as version_end_date   -- NULL = current row
        , 1 as version_number
        , 'Initial load' as scd_change_reason

        , 'silver_d365_inventory_location + silver_d365_inventory_site' as record_source_table
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

        , {{ generate_row_hash([
              "coalesce(b.warehouse_name, '')",
              "coalesce(case when b.d365_location_type in ('1', '2') then 'Virtual' end, '')",
              "coalesce(cast(case when b.d365_location_type in ('1', '2') then 0 else 1 end as string), '')",
              "coalesce(cast(case when b.d365_location_type in ('1', '2') then 0 else 1 end as string), '')",
              "coalesce('Active', '')",
              "coalesce(cast(1 as string), '')"
          ]) }} as row_hash -- hashes the currently-populated Type 2 (history-tracked) attributes per the spec's SCD2 Tracking Plan (section 4); extend this list as null placeholders above get wired to real sources (warehouse_subtype, fulfillment_priority, address/city/state/country, order_cutoff_time, capacity_sqft/storage_capacity_units, operator_name)

    from warehouse_base b

)

select * from final
