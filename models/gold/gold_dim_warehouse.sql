{{ config(materialized = 'table') }}

WITH base_data as 
    (
    SELECT distinct
        l.location_key
        , l.INVENTLOCATIONID as warehouse_id
        , l.name as warehouse_name
        , s.siteid as site_id
        , s.name as site_name
        , '' as warehouse_short_name 
        , '' as warehouse_description 
        , l.inventlocationtype as warehouse_type
        , '' as warehouse_subtype 
        , '' as is_fulfillment_enabled
        , '' as is_receiving_enabled 
        , '' as is_transfer_enabled 
        , '' as is_returns_enabled 
        , '' AS address_line_1
        , '' AS address_line_2
        , '' AS city
        , '' AS state_province
        , '' AS postal_code
        , '' AS country_code
        , '' AS country_key
        , '' AS geo_region
        , '' AS latitude
        , '' AS longitude
        , '' AS timezone
        , '' AS operating_hours_start
        , '' AS operating_hours_end
        , '' AS order_cutoff_time
        , '' AS capacity_sqft
        , '' AS storage_capacity_units
        , '' AS operator_name
        , '' AS wms_system
        , l.INVENTLOCATIONID as d365_warehouse_id
        , s.siteid as d365_site_id
        , '' AS d365_location_type
        , l.defaultstatusid as warehouse_status
        , '' AS active_flag
        , '' AS effective_open_date
        , '' AS effective_close_date
        , '' AS is_current_row
        , '' AS version_start_date
        , '' AS version_end_date
        , '' AS version_number
        , '' AS scd_change_reason
        , '' AS record_source_table
        , '' AS etl_insert_datetime
        , '' AS etl_update_datetime
        , '' AS row_hash
    From
        {{ref("silver_byod_inventory_site")}} s
        left join {{ref("silver_byod_inventory_location")}} l on s.siteid = l.inventsiteid
    )

select
    md5(concat_ws('|',ifnull(bd.warehouse_id,'0'), ifnull(bd.site_id,'0'))) AS warehouse_key
    , *
FROM
    base_data bd