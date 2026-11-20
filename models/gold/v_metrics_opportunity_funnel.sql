{{ config(materialized = 'view') }}

-- One row per pipeline opportunity per funnel stage. Stage-to-stage conversion for stage N =
-- sum(is_advanced_past_stage) / sum(is_stage_reached) at funnel_stage_order N; filter is_closed = true for a settled cohort.

with opportunity as (

    select o.*
    from {{ ref('fact_opportunity') }} o

),

funnel_stage as (

    select
          s.stage_name
        , cast(s.stage_order as int) as stage_order
    from {{ ref('sales_stage_map') }} s
    where s.object_name = 'Opportunity'
      and s.is_funnel_stage = '1'

),

entered_stage as (

    select distinct
          h.opportunity_key
        , h.stage_order
    from {{ ref('fact_opportunity_stage_history') }} h
    where h.stage_order is not null

),

final as (

    select

          o.opportunity_key
        , o.sfdc_opportunity_id
        , o.owner_user_key
        , u.user_name as owner_name
        , o.sales_motion
        , o.account_segment
        , o.customer_group
        , o.created_date
        , date_format(o.created_date, 'yyyy-MM') as created_month
        , fs.stage_order as funnel_stage_order
        , fs.stage_name as funnel_stage_name
        , coalesce(o.highest_stage_order, 0) >= fs.stage_order as is_stage_reached
        , es.opportunity_key is not null as is_stage_recorded
        , coalesce(o.highest_stage_order, 0) >= fs.stage_order and es.opportunity_key is null as is_stage_skipped
        , coalesce(o.highest_stage_order, 0) > fs.stage_order as is_advanced_past_stage
        , o.entry_stage_name
        , o.highest_stage_name
        , o.stage_name as current_stage_name
        , o.is_created_closed
        , o.is_reopened
        , o.is_closed
        , o.is_won
        , o.amount
        , o.sales_cycle_days

    from opportunity o
    cross join funnel_stage fs
    left join entered_stage es
        on es.opportunity_key = o.opportunity_key
       and es.stage_order = fs.stage_order
    left join {{ ref('dim_crm_user') }} u
        on u.user_key = o.owner_user_key

)

select * from final
