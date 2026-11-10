{{ config(materialized = 'view') }}

-- months_of_* count whole months (end date + 1 day), so a 3+9 returns 3 and 9.
select

      df.* except (row_hash, etl_insert_datetime, etl_update_datetime)
    , case
        when df.forecast_cycle is null then df.forecast_display_name
        else concat(df.forecast_display_name, ' (', df.forecast_cycle, ')')
      end as forecast_label
    , case
        when df.actuals_through_date is null then 0
        else cast(timestampdiff(MONTH, df.coverage_start_date, date_add(df.actuals_through_date, 1)) as int)
      end as months_of_actuals
    , cast(timestampdiff(MONTH, df.forecast_start_date, date_add(df.coverage_end_date, 1)) as int) as months_of_forecast

from {{ ref('dim_forecast') }} df
where df.forecast_status in ('Published', 'Superseded')
