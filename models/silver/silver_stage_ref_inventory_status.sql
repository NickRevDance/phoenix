{{ config(materialized = 'table') }}

SELECT
    xxhash64(t.inventory_status_code) AS inventory_status_key
    ,t.inventory_status_code
    ,t.status_description
    ,t.ownership_type
    ,t.availability_class
    ,t.program_name
    ,t.partner_customer_id
    ,cast(t.is_sellable_flag as int) AS is_sellable_flag
    ,cast(t.include_in_std_metrics_flag as int) AS include_in_std_metrics_flag
    ,t.notes
    ,'manual' AS source_system
    ,'{{ this.identifier }}' AS record_source_table
    ,md5(
        concat_ws('|'
            ,t.ownership_type
            ,t.availability_class
            ,ifnull(t.program_name, '')
            ,ifnull(t.partner_customer_id, '')
            ,cast(t.is_sellable_flag as string)
            ,cast(t.include_in_std_metrics_flag as string)
        )
    ) AS status_change_hash

FROM (

    SELECT * FROM VALUES

          ('Available'  , 'Standard available inventory'                  , 'COMPANY_OWNED' , 'AVAILABLE' , cast(null as string) , cast(null as string) , true  , true  , 'Default sellable status; 11,908,568 live rows as of 2026-08-18')
        , ('Blocked'    , 'Inventory placed on hold, not sellable'        , 'COMPANY_OWNED' , 'HOLD'      , cast(null as string) , cast(null as string) , false , true  , 'NEEDS CONFIRMATION -- classification not yet reviewed by Nick; 7,700 live rows')
        , ('Tippi Toes' , 'Partner-owned inventory -- Tippi Toes program' , 'PARTNER_OWNED' , 'PARTNER'   , 'Tippi Toes'          , cast(null as string) , false , false , 'NEEDS CONFIRMATION -- assumed EDW-32 dropship partner; partner_customer_id not sourced; 47,670 live rows')
        , ('2Die4'      , 'Partner-owned inventory -- 2Die4 program'      , 'PARTNER_OWNED' , 'PARTNER'   , '2Die4'               , cast(null as string) , false , false , 'NEEDS CONFIRMATION -- assumed EDW-32 dropship partner; only 10 live rows, confirm still active; partner_customer_id not sourced')
        , ('UNKNOWN'    , 'Unmapped/unclassified inventory status'        , 'COMPANY_OWNED' , 'UNKNOWN'   , cast(null as string) , cast(null as string) , false , false , 'Default DQ-exception member per EDW-7 pattern -- snapshot/movement rows with an inventory_status_code not present in this table route here')

    AS v(
          inventory_status_code
        , status_description
        , ownership_type
        , availability_class
        , program_name
        , partner_customer_id
        , is_sellable_flag
        , include_in_std_metrics_flag
        , notes
    )

) t
