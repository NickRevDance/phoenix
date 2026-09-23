{{ config(materialized = 'view') }}

-- EDW-91: filters on is_current_row, not version_number. With
-- hard_deletes: invalidate on silver_snapshot_dim_vendor, a vendor
-- removed from D365 has its open version closed with no successor, so
-- it still ranks version_number = 1 and a version-only filter would
-- keep serving it as current. is_current_row carries the open-end test
-- (scd2_is_current_row macro). Spec Section 9, DIM_VENDOR v1.1.

SELECT
    dv.* EXCEPT
        (
            vendor_change_hash
            , row_hash
            , effective_start_datetime
            , effective_end_datetime
            , version_number
            , is_current_row
            , record_source_table
            , etl_update_datetime
        )
FROM
    {{ref("dim_vendor")}} dv
WHERE
    is_current_row = 1
