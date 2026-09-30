{{ config(materialized = 'table') }}

-- Reads the seed directly and casts here (no silver stage model): this is
-- BI-maintained configuration with no source-system input, the same way
-- dim_date reads retail_calendar_years.

with seed_typed as (

    select

          trim(s.parameter_name) as parameter_name
        , cast(s.parameter_value as decimal(18,6)) as parameter_value
        , trim(s.unit) as unit
        , cast(s.is_active as int) as is_active
        , cast(s.effective_start_date as date) as effective_start_date
        , cast(s.effective_end_date as date) as effective_end_date
        , nullif(trim(s.notes), '') as notes

    from {{ ref('demand_planning_thresholds_seed') }} s

),

final as (

    select

          {{ generate_surrogate_key(['t.parameter_name', 't.effective_start_date']) }} as threshold_key  -- version-distinct key, matching ref_inventory_quality_thresholds (natural key + effective_start_date)

        , t.parameter_name
        , t.parameter_value
        , t.unit

        , t.is_active
        , t.effective_start_date
        , t.effective_end_date
        , t.notes
        , 'demand_planning_thresholds_seed' as record_source
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

    from seed_typed t

)

select * from final