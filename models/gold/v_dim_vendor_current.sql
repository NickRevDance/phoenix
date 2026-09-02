{{ config(materialized = 'view') }}

SELECT
    dv.* EXCEPT
        (
            vendor_change_hash
            , row_hash
            , effective_start_datetime
            , effective_end_datetime
            , version_number
            , is_current_row
            , etl_update_datetime
        )
FROM
    {{ref("dim_vendor")}} dv
WHERE
    version_number = 1
