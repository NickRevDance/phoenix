{{ config(materialized = 'view') }}

SELECT
    inv_s.* EXCEPT 
        (
            record_source_table
            , row_hash
            , etl_update_datetime
            , version_start_date
            , version_end_date
            , version_number
            , is_current_row
        )
FROM
    {{ref("ref_inventory_status")}} inv_s
WHERE
    is_current_row = 1