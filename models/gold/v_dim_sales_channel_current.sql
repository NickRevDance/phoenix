{{ config(materialized = 'view') }}

-- Type 1 table, no version history -- this is a column-projection
-- pass-through (spec Section 3.9), not a version_number = 1 filter like
-- the SCD2 _current views (v_dim_vendor_current, v_dim_customer_current).
-- Retained purely for interface consistency: every dimension exposes a
-- _current view that Power BI and other facts bind to, so an SCD2 upgrade
-- later is invisible to consumers.

SELECT
    dsc.* EXCEPT
        (
            row_hash
            , etl_insert_datetime
            , etl_update_datetime
        )
FROM
    {{ ref("dim_sales_channel") }} dsc
