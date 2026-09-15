{{ config(materialized = 'view') }}

SELECT
    fpo.* EXCEPT
        (
            version_start_datetime
            , version_end_datetime
            , is_current_row
            , etl_update_datetime
            , row_hash
        )
FROM
    {{ref("fact_purchase_order")}} fpo
WHERE
    is_current_row = true
