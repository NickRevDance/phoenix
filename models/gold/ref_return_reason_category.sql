{{ config(materialized = 'table') }}

-- Reads the seed directly and casts here (no silver stage model): this is a
-- BI-maintained classification with no source-system input, the same way
-- dim_date reads retail_calendar_years.

with seed_typed as (

    select

          coalesce(trim(s.return_reason_code), '') as return_reason_code  -- the blank-code row: D365 stores an empty string on a return order with no reason, and the seed loads that row's code as null
        , trim(s.return_reason_category) as return_reason_category
        , nullif(trim(s.classification_owner), '') as classification_owner
        , cast(s.classified_date as date) as classified_date
        , nullif(trim(s.notes), '') as notes

    from {{ ref('return_reason_category') }} s

),

final as (

    select

          t.return_reason_code
        , t.return_reason_category
        , t.classification_owner
        , t.classified_date
        , t.notes
        , 'return_reason_category' as record_source
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

    from seed_typed t

)

select * from final