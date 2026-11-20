{{ config(materialized = 'table') }}

-- One row per stage an opportunity entered (amount/close-date-only history rows are dropped). Pipeline opportunities only.

with opportunity as (

    select
          o.opportunity_key
        , o.sfdc_opportunity_id
        , o.customer_key
        , o.owner_user_key
        , o.sales_motion
    from {{ ref('fact_opportunity') }} o

),

crm_user as (

    select u.Id
    from {{ ref('silver_sfdc_user') }} u

),

stage_change as (

    select

          h.*
        , row_number() over (partition by h.OpportunityId order by h.CreatedDate, h.Id) as stage_sequence_number
        , lead(h.CreatedDate) over (partition by h.OpportunityId order by h.CreatedDate, h.Id) as next_stage_entered_datetime

    from {{ ref('silver_sfdc_opportunity_history') }} h
    where h.is_stage_change

),

shaped as (

    select

          sc.*
        , cast(from_utc_timestamp(sc.CreatedDate, 'America/Chicago') as date) as stage_entered_date
        , cast(from_utc_timestamp(sc.next_stage_entered_datetime, 'America/Chicago') as date) as stage_exited_date

    from stage_change sc

),

final as (

    select

          {{ generate_surrogate_key(['s.Id', "'SFDC'"]) }} as opportunity_stage_history_key
        , s.Id as sfdc_opportunity_history_id
        , o.opportunity_key
        , o.customer_key
        , o.owner_user_key
        , case
            when u.Id is not null then {{ generate_surrogate_key(['s.CreatedById', "'SFDC'"]) }}
            else cast({{ unknown_member_key() }} as bigint)
          end as changed_by_user_key
        , o.sales_motion
        , s.stage_sequence_number
        , s.StageName as stage_name
        , s.stage_order
        , s.stage_outcome
        , s.prior_stage_name
        , s.prior_stage_order
        , s.stage_sequence_number = 1 as is_entry_stage
        , s.next_stage_entered_datetime is null as is_current_stage
        , s.is_reopen
        , s.is_backward_move
        , s.CreatedDate as stage_entered_datetime
        , s.stage_entered_date
        , cast(date_format(s.stage_entered_date, 'yyyyMMdd') as int) as stage_entered_date_key
        , s.next_stage_entered_datetime as stage_exited_datetime
        , s.stage_exited_date
        , cast(date_format(s.stage_exited_date, 'yyyyMMdd') as int) as stage_exited_date_key
        , datediff(s.stage_exited_date, s.stage_entered_date) as days_in_stage
        , case when s.stage_outcome = 'Open'
               then datediff(coalesce(s.stage_exited_date, current_date()), s.stage_entered_date)
          end as days_in_stage_to_date
        , {{ amount('s.Amount') }} as amount_at_entry
        , s.Probability as probability_pct_at_entry
        , s.CloseDate as close_date_at_entry
        , 'silver_sfdc_opportunity_history' as record_source
        , {{ audit_columns() }}

    from shaped s
    inner join opportunity o
        on o.sfdc_opportunity_id = s.OpportunityId
    left join crm_user u
        on u.Id = s.CreatedById

)

select * from final
