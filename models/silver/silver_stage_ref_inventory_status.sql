{{ config(materialized = 'table') }}

SELECT
    xxhash64(t.inventory_status_code) AS inventory_status_key
    ,t.inventory_status_code
    ,t.status_description
    ,t.ownership_type
    ,t.availability_class
    ,t.program_name
    ,t.partner_customer_id
    ,t.is_sellable_flag
    ,t.include_in_std_metrics_flag
    ,t.notes
    ,'Manual' as source_system
    ,'bronze_ref_inventory_status' AS record_source_table
    ,md5(
        concat_ws('|'
            ,t.ownership_type
            ,t.availability_class
            ,ifnull(t.program_name, '')
            ,ifnull(t.partner_customer_id, '')
            ,t.is_sellable_flag
            ,t.include_in_std_metrics_flag
        )
    ) AS status_change_hash

FROM {{ref("bronze_ref_inventory_status")}} t
