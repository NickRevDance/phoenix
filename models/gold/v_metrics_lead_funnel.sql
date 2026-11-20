{{ config(materialized = 'view') }}

-- One row per lead with cumulative funnel flags. Lead status history isn't tracked in Salesforce, so the flags come from the current status.

with lead_fact as (

    select l.*
    from {{ ref('fact_lead') }} l

),

final as (

    select

          l.lead_key
        , l.sfdc_lead_id
        , l.owner_user_key
        , u.user_name as owner_name
        , l.first_crm_campaign_key
        , c.campaign_name as first_campaign_name
        , c.campaign_type as first_campaign_type
        , l.lead_source
        , l.lead_status
        , l.lead_outcome
        , l.created_date
        , date_format(l.created_date, 'yyyy-MM') as created_month
        , l.is_converted or coalesce(l.status_order, 0) >= 2 as is_working_or_later
        , l.is_converted or coalesce(l.status_order, 0) >= 3 as is_qualified_or_later
        , l.is_converted
        , l.is_existing_customer_at_conversion
        , l.is_new_customer_conversion
        , l.is_converted_to_opportunity
        , coalesce(o.is_won, false) as is_converted_opportunity_won
        , l.converted_date
        , l.days_to_convert

    from lead_fact l
    left join {{ ref('dim_crm_user') }} u
        on u.user_key = l.owner_user_key
    left join {{ ref('dim_crm_campaign') }} c
        on c.crm_campaign_key = l.first_crm_campaign_key
    left join {{ ref('fact_opportunity') }} o
        on o.opportunity_key = l.converted_opportunity_key

)

select * from final
