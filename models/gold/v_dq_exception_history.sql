{{ config(materialized='view') }}

with final as (

    select
          test_unique_id
        , test_name
        , test_type
        , model_name
        , column_name
        , severity
        , status
        , failures
        , run_started_at
    from {{ source('dq_internal', 'dq_test_run_log') }}
    where status in ('warn', 'fail', 'error')

)

select * from final
