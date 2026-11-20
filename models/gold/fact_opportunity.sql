{{ config(materialized = 'table') }}

-- Pipeline opportunities only; the Sales Order record type mirrors orders and is left out.

with opportunity as (

    select o.*
    from {{ ref('silver_sfdc_opportunity') }} o
    where o.is_pipeline_opportunity
      and o.IsDeleted = false

),

crm_user as (

    select u.Id
    from {{ ref('silver_sfdc_user') }} u

),

shaped as (

    select

          o.*
        , cast(from_utc_timestamp(o.CreatedDate, 'America/Chicago') as date) as created_date
        , case when o.IsClosed
               then coalesce(cast(from_utc_timestamp(o.closed_datetime, 'America/Chicago') as date), o.CloseDate)
          end as closed_date

    from opportunity o

),

final as (

    select

          {{ generate_surrogate_key(['o.Id', "'SFDC'"]) }} as opportunity_key
        , o.Id as sfdc_opportunity_id
        , coalesce(acm.customer_key, cast({{ unknown_member_key() }} as bigint)) as customer_key
        , o.AccountId as sfdc_account_id
        , case
            when u.Id is not null then {{ generate_surrogate_key(['o.OwnerId', "'SFDC'"]) }}
            else cast({{ unknown_member_key() }} as bigint)
          end as owner_user_key
        , case when o.converted_from_lead_id is not null then {{ generate_surrogate_key(['o.converted_from_lead_id', "'SFDC'"]) }} end as lead_key
        , o.Name as opportunity_name
        , o.record_type_name as sales_motion
        , o.StageName as stage_name
        , o.stage_order
        , o.stage_outcome
        , o.entry_stage_name
        , o.highest_stage_order
        , o.highest_stage_name
        , o.stage_change_count
        , o.is_created_closed
        , o.is_reopened
        , o.has_backward_move
        , o.IsClosed as is_closed
        , o.IsWon as is_won
        , o.ForecastCategoryName as forecast_category
        , o.Probability as probability_pct
        , {{ amount('o.Amount') }} as amount
        , {{ amount('o.ExpectedRevenue') }} as expected_revenue
        , o.Account_Segment__c as account_segment
        , o.Customer_Group__c as customer_group
        , o.LeadSource as lead_source
        , o.Loss_Reason__c as loss_reason
        , o.PushCount as close_date_push_count
        , o.CreatedDate as created_datetime
        , o.created_date
        , cast(date_format(o.created_date, 'yyyyMMdd') as int) as created_date_key
        , o.CloseDate as close_date
        , cast(date_format(o.CloseDate, 'yyyyMMdd') as int) as close_date_key
        , o.closed_datetime
        , o.closed_date
        , cast(date_format(o.closed_date, 'yyyyMMdd') as int) as closed_date_key
        , o.current_stage_entered_datetime
        , datediff(o.closed_date, o.created_date) as sales_cycle_days
        , 'silver_sfdc_opportunity' as record_source
        , {{ audit_columns() }}

    from shaped o
    left join {{ ref('v_crm_account_customer_map') }} acm
        on acm.sfdc_account_id = o.AccountId
    left join crm_user u
        on u.Id = o.OwnerId

)

select * from final
