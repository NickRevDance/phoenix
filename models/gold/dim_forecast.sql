{{ config(materialized = 'table') }}

with seed_typed as (

    select

          trim(s.forecast_version_id) as forecast_version_id
        , trim(s.source_system) as source_system
        , trim(s.forecast_name) as forecast_name
        , trim(s.forecast_display_name) as forecast_display_name
        , nullif(trim(s.forecast_description), '') as forecast_description
        , trim(s.forecast_type) as forecast_type
        , nullif(trim(s.forecast_subtype), '') as forecast_subtype
        , nullif(trim(s.forecast_cycle), '') as forecast_cycle
        , cast(s.fiscal_year as int) as fiscal_year
        , cast(s.coverage_start_date as date) as coverage_start_date
        , cast(s.coverage_end_date as date) as coverage_end_date
        , cast(nullif(trim(s.actuals_through_date), '') as date) as actuals_through_date
        , cast(nullif(trim(s.forecast_start_date), '') as date) as seed_forecast_start_date
        , coalesce(cast(nullif(trim(s.version_number), '') as int), 1) as version_number
        , nullif(trim(s.time_grain), '') as time_grain
        , nullif(trim(s.product_grain), '') as product_grain
        , nullif(trim(s.channel_grain), '') as channel_grain
        , trim(s.forecast_status) as forecast_status
        , cast(nullif(trim(s.status_change_datetime), '') as timestamp) as status_change_datetime
        , cast(nullif(trim(s.published_datetime), '') as timestamp) as published_datetime
        , coalesce(nullif(trim(s.created_by), ''), 'FP&A') as created_by
        , cast(s.created_datetime as timestamp) as created_datetime
        , nullif(trim(s.record_source_table), '') as record_source_table

    from {{ ref('forecast_version') }} s

),

fiscal_years as (

    select

          d.fiscal_year
        , min(d.date_key) as fiscal_year_key

    from {{ ref('dim_date') }} d
    where d.date_key > 0
    group by d.fiscal_year

),

derived as (

    select

          t.*
        , fy.fiscal_year_key
        , case
            when t.forecast_type = 'Annual Budget' then t.coverage_start_date
            when t.forecast_type = 'Periodic Reforecast' then date_add(t.actuals_through_date, 1)
            else coalesce(t.seed_forecast_start_date, date_add(t.actuals_through_date, 1), t.coverage_start_date)
          end as forecast_start_date
        , case
            when t.forecast_type = 'Annual Budget' then 10
            when t.forecast_type = 'Periodic Reforecast' and t.forecast_cycle = '3+9' then 20
            when t.forecast_type = 'Periodic Reforecast' and t.forecast_cycle = '6+6' then 30
            when t.forecast_type = 'Periodic Reforecast' and t.forecast_cycle = '9+3' then 40
            when t.forecast_type = 'Periodic Reforecast' then 45
            when t.forecast_type = 'Operational Forecast' then 50
            when t.forecast_type = 'Rolling Forecast' then 60
            when t.forecast_type = 'Scenario' then 90
          end as sort_order
        , case
            when t.forecast_status = 'Published' and t.forecast_type = 'Periodic Reforecast' then 0
            when t.forecast_status = 'Published' and t.forecast_type = 'Annual Budget' then 1
          end as primary_priority

    from seed_typed t
    left join fiscal_years fy
        on fy.fiscal_year = t.fiscal_year

),

ranked as (

    select

          d.*
        , row_number() over (
            partition by d.fiscal_year
            order by
                  d.primary_priority asc nulls last
                , d.actuals_through_date desc nulls last
                , d.version_number desc
                , d.published_datetime desc nulls last
          ) as primary_rank
        , row_number() over (
            partition by d.fiscal_year, d.forecast_type, d.forecast_status
            order by
                  d.actuals_through_date desc nulls last
                , d.version_number desc
                , d.published_datetime desc nulls last
          ) as reforecast_rank

    from derived d

),

final as (

    select

          {{ generate_surrogate_key(['r.forecast_version_id', 'r.source_system']) }} as forecast_version_key
        , r.forecast_version_id
        , r.source_system
        , r.forecast_name
        , r.forecast_display_name
        , r.forecast_description
        , r.forecast_type
        , r.forecast_subtype
        , r.forecast_cycle
        , cast(null as string) as forecast_domain  -- Source once available: seed column -- Phase 2 per spec
        , r.fiscal_year
        , r.fiscal_year_key
        , r.coverage_start_date
        , r.coverage_end_date
        , r.actuals_through_date
        , r.forecast_start_date
        , r.version_number
        , case when r.primary_priority is not null and r.primary_rank = 1 then 1 else 0 end as is_primary_version
        , case
            when r.forecast_type <> 'Periodic Reforecast' then cast(null as int)
            when r.forecast_status = 'Published' and r.reforecast_rank = 1 then 1
            else 0
          end as is_latest_reforecast
        , cast(null as bigint) as supersedes_version_key  -- Source once available: seed column -- Phase 2 per spec
        , r.time_grain
        , r.product_grain
        , r.channel_grain
        , r.forecast_status
        , r.status_change_datetime
        , r.published_datetime
        , r.created_by
        , cast(null as string) as approved_by  -- Source once available: Planful user metadata -- Phase 2 per spec
        , r.created_datetime
        , r.sort_order
        , r.record_source_table
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime
        , {{ generate_row_hash([
              "coalesce(r.forecast_name, '')"
            , "coalesce(r.forecast_display_name, '')"
            , "coalesce(r.forecast_description, '')"
            , "coalesce(r.forecast_type, '')"
            , "coalesce(r.forecast_subtype, '')"
            , "coalesce(r.forecast_cycle, '')"
            , "coalesce(cast(r.fiscal_year as string), '')"
            , "coalesce(cast(r.coverage_start_date as string), '')"
            , "coalesce(cast(r.coverage_end_date as string), '')"
            , "coalesce(cast(r.actuals_through_date as string), '')"
            , "coalesce(cast(r.version_number as string), '')"
            , "coalesce(r.forecast_status, '')"
            , "coalesce(cast(r.published_datetime as string), '')"
          ]) }} as row_hash

    from ranked r

)

select * from final
