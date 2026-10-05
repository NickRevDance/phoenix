{{ config(materialized = 'table') }}

-- REF_STOCKING_POLICY (EDW-144; DIM_PRODUCT spec v1.3 Section 8, Inventory spec Section 5).
-- One row per D365 item whose stocking policy is not the default. An item with no row is
-- STOCKED. MADE_TO_ORDER items carry a seeded placeholder quantity in D365 so orders are never
-- blocked; it is not stock, and the certified inventory views leave those items out of on-hand
-- quantity, value and every supply metric. Sales and margin treat them as ordinary merchandise.
-- Keyed on product_id (D365 item), not product_key: the made-to-order family is not in
-- DIM_PRODUCT, so a rule keyed on the dimension could not reach it.
-- Reads the seed directly and casts here (no silver stage model): this is a BI-maintained
-- classification with no source-system input, the same way ref_return_reason_category does.

with seed_typed as (

    select

          trim(s.product_id) as product_id
        , upper(trim(s.stocking_policy)) as stocking_policy
        , nullif(trim(s.classification_owner), '') as classification_owner
        , cast(s.classified_date as date) as classified_date
        , nullif(trim(s.notes), '') as notes

    from {{ ref('stocking_policy') }} s

),

final as (

    select

          t.product_id
        , t.stocking_policy
        , t.classification_owner
        , t.classified_date
        , t.notes
        , 'stocking_policy' as record_source
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

    from seed_typed t

)

select * from final
