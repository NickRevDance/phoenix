{{ config(materialized = 'table') }}

-- REF_SUMMARY_CLASS_ROLLUP (EDW-125). One row per Finance summary class with the reporting
-- rollups above it, so the loyalty reports and the daily sales report read one mapping and
-- cannot drift:
--   reporting_category_group / reporting_subcategory  - the daily sales view (Costumes,
--       Dancewear, 2Die4 DTC, Revolution Apparel), with Tights under Dancewear
--   loyalty_reporting_category                         - the Revolution Rewards view (Costumes,
--       Dancewear (excl. Tights), Tights, Branded Apparel); it follows the earn rules, so
--       Tights is its own bucket and costume spend is the tier-qualifying spend
-- It rolls up summary_class; it does not classify products. Product to summary class stays in
-- ref_product_summary_class. DIM_PRODUCT joins this table on summary_class and reads Other
-- where a class has no row here.
-- Reads the seed directly and casts here (no silver stage model): a BI-maintained
-- classification with no source-system input, the same way ref_stocking_policy does.

with seed_typed as (

    select

          trim(s.summary_class) as summary_class
        , trim(s.reporting_category_group) as reporting_category_group
        , cast(s.reporting_category_group_sort as int) as reporting_category_group_sort
        , trim(s.reporting_subcategory) as reporting_subcategory
        , cast(s.reporting_subcategory_sort as int) as reporting_subcategory_sort
        , trim(s.loyalty_reporting_category) as loyalty_reporting_category
        , cast(s.loyalty_reporting_category_sort as int) as loyalty_reporting_category_sort
        , nullif(trim(s.classification_owner), '') as classification_owner
        , cast(s.classified_date as date) as classified_date
        , nullif(trim(s.notes), '') as notes

    from {{ ref('summary_class_rollup') }} s

),

final as (

    select

          t.*
        , 'summary_class_rollup' as record_source
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

    from seed_typed t

)

select * from final
