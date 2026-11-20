{{ config(materialized = 'view') }}

-- Open pipeline at opportunity grain, with age and stage-aging measures as of today.

with open_opportunity as (

    select o.*
    from {{ ref('fact_opportunity') }} o
    where o.is_closed = false

),

opportunity_activity as (

    select
          f.opportunity_key
        , max(f.activity_date) as last_opportunity_activity_date
    from {{ ref('fact_crm_activity') }} f
    where f.opportunity_key is not null
      and f.is_automated = false
      and f.activity_date <= current_date()
    group by f.opportunity_key

),

final as (

    select

          o.opportunity_key
        , o.sfdc_opportunity_id
        , o.opportunity_name
        , o.customer_key
        , c.customer_name
        , o.owner_user_key
        , u.user_name as owner_name
        , o.sales_motion
        , o.account_segment
        , o.customer_group
        , o.stage_name
        , o.stage_order
        , o.entry_stage_name
        , o.forecast_category
        , o.probability_pct
        , o.amount
        , o.expected_revenue
        , o.created_date
        , o.close_date
        , date_format(o.close_date, 'yyyy-MM') as close_month
        , o.close_date < current_date() as is_past_close_date
        , o.close_date_push_count
        , datediff(current_date(), o.created_date) as opportunity_age_days
        , datediff(current_date(), cast(from_utc_timestamp(o.current_stage_entered_datetime, 'America/Chicago') as date)) as days_in_current_stage
        , case
            when datediff(current_date(), o.created_date) <= 30 then '0-30 days'
            when datediff(current_date(), o.created_date) <= 90 then '31-90 days'
            when datediff(current_date(), o.created_date) <= 180 then '91-180 days'
            else '181+ days'
          end as opportunity_age_bucket
        , oa.last_opportunity_activity_date
        , datediff(current_date(), coalesce(oa.last_opportunity_activity_date, o.created_date)) as days_since_opportunity_activity
        , e.last_contact_date as last_account_contact_date
        , e.last_owner_contact_date as last_account_owner_contact_date
        , e.days_since_last_contact as days_since_account_contact

    from open_opportunity o
    left join {{ ref('v_dim_customer_current') }} c
        on c.customer_key = o.customer_key
    left join {{ ref('dim_crm_user') }} u
        on u.user_key = o.owner_user_key
    left join opportunity_activity oa
        on oa.opportunity_key = o.opportunity_key
    left join {{ ref('fact_crm_account_engagement') }} e
        on e.sfdc_account_id = o.sfdc_account_id

)

select * from final
