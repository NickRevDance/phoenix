
{{ config(materialized = 'view', schema = 'marketing_gold') }}
 
-- Spec section 8 also joins DIM_CUSTOMER_SEGMENT, DIM_COUNTRY, and
-- DIM_SALES_CHANNEL for a fully flattened row. None of those three exist
-- in this project yet, so this view is DIM_CUSTOMER's current row only --
-- add the joins once those dimensions are built.
 
SELECT
    dc.* EXCEPT
        (
            customer_change_hash
            , row_hash
            , effective_start_datetime
            , effective_end_datetime
            , version_number
            , is_current_row
            , etl_update_datetime
        )
FROM
    {{ref("dim_customer")}} dc
WHERE
    version_number = 1