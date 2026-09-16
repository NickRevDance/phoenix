{{ config(materialized='view') }}

with latest_run as (

    select
          test_unique_id
        , max(run_started_at) as last_run_at
    from {{ source('dq_internal', 'dq_test_run_log') }}
    group by test_unique_id

),

current_status as (

    select
          log.test_unique_id
        , log.test_name
        , log.test_type
        , log.model_name
        , log.column_name
        , log.severity
        , log.status
        , log.failures
        , log.message
        , log.run_started_at as last_run_at
    from {{ source('dq_internal', 'dq_test_run_log') }} as log
    inner join latest_run
        on log.test_unique_id = latest_run.test_unique_id
        and log.run_started_at = latest_run.last_run_at

),

first_seen as (

    select
          test_unique_id
        , min(run_started_at) as first_flagged_at
    from {{ source('dq_internal', 'dq_test_run_log') }}
    where status in ('warn', 'fail', 'error')
    group by test_unique_id

),

final as (

    select
          cs.test_unique_id
        , cs.test_name
        , cs.test_type
        , cs.model_name
        , cs.column_name
        , cs.severity
        , cs.status
        , cs.failures
        , cs.message
        , fs.first_flagged_at
        , cs.last_run_at
    from current_status as cs
    left join first_seen as fs
        on cs.test_unique_id = fs.test_unique_id
    where cs.status in ('warn', 'fail', 'error')

)

select * from final
