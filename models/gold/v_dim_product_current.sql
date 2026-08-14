{{ config(materialized = 'view') }}

SELECT
    snap_p.* EXCEPT 
        (
            product_change_hash
            , row_hash
            , dbt_updated_at
            , effective_start_datetime
            , effective_end_datetime
            , version_number
            , is_current_row
            , record_source_table
            , etl_insert_datetime
            , etl_update_datetime
        )
FROM
    {{ref("dim_product")}} snap_p
WHERE
    version_number = 1