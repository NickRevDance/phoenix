{{ config(materialized = 'view') }}

-- One row per campaign. Opportunities carry no CampaignId, so influence is by account: a pipeline opportunity on a member's
-- account created within crm_campaign_influence_days (default 90) after the member was added.

with campaign as (

    select c.*
    from {{ ref('dim_crm_campaign') }} c
    where c.crm_campaign_key not in ({{ unknown_member_key() }}, {{ default_member_key() }})

),

member_summary as (

    select
          m.crm_campaign_key
        , count(*) as member_count
        , count_if(m.member_type = 'Lead') as lead_member_count
        , count_if(m.member_type = 'Contact') as contact_member_count
        , count_if(m.has_responded) as responded_member_count
        , count(distinct case when m.customer_key <> {{ unknown_member_key() }} then m.customer_key end) as member_customer_count
        , min(m.added_date) as first_member_added_date
        , max(m.added_date) as last_member_added_date
    from {{ ref('fact_campaign_member') }} m
    group by m.crm_campaign_key

),

lead_summary as (

    select
          l.first_crm_campaign_key as crm_campaign_key
        , count(*) as lead_count
        , count_if(l.is_converted) as lead_converted_count
        , count_if(l.is_new_customer_conversion) as new_customer_conversion_count
    from {{ ref('fact_lead') }} l
    group by l.first_crm_campaign_key

),

influenced as (

    select distinct
          m.crm_campaign_key
        , o.opportunity_key
        , o.is_closed
        , o.is_won
        , o.amount
    from {{ ref('fact_campaign_member') }} m
    inner join {{ ref('fact_opportunity') }} o
        on o.sfdc_account_id = m.sfdc_account_id
       and o.created_date >= m.added_date
       and o.created_date <= date_add(m.added_date, {{ var('crm_campaign_influence_days', 90) }})

),

influence_summary as (

    select
          i.crm_campaign_key
        , count(*) as influenced_opportunity_count
        , count_if(i.is_won) as influenced_won_opportunity_count
        , {{ amount('sum(i.amount)') }} as influenced_pipeline_amount
        , {{ amount('sum(case when i.is_won then i.amount end)') }} as influenced_won_amount
    from influenced i
    group by i.crm_campaign_key

),

final as (

    select

          c.crm_campaign_key
        , c.sfdc_campaign_id
        , c.campaign_name
        , c.campaign_type
        , c.campaign_status
        , c.is_active
        , c.parent_campaign_name
        , c.start_date
        , c.end_date
        , c.budgeted_cost
        , c.actual_cost
        , coalesce(ms.member_count, 0) as member_count
        , coalesce(ms.lead_member_count, 0) as lead_member_count
        , coalesce(ms.contact_member_count, 0) as contact_member_count
        , coalesce(ms.responded_member_count, 0) as responded_member_count
        , coalesce(ms.member_customer_count, 0) as member_customer_count
        , ms.first_member_added_date
        , ms.last_member_added_date
        , coalesce(ls.lead_count, 0) as lead_count
        , coalesce(ls.lead_converted_count, 0) as lead_converted_count
        , coalesce(ls.new_customer_conversion_count, 0) as new_customer_conversion_count
        , coalesce(isum.influenced_opportunity_count, 0) as influenced_opportunity_count
        , coalesce(isum.influenced_won_opportunity_count, 0) as influenced_won_opportunity_count
        , coalesce(isum.influenced_pipeline_amount, 0) as influenced_pipeline_amount
        , coalesce(isum.influenced_won_amount, 0) as influenced_won_amount
        , ms.responded_member_count / nullif(ms.member_count, 0) as response_rate
        , ls.lead_converted_count / nullif(ls.lead_count, 0) as lead_conversion_rate
        , {{ amount('c.actual_cost / nullif(ms.responded_member_count, 0)') }} as cost_per_response
        , {{ amount('c.actual_cost / nullif(ls.lead_count, 0)') }} as cost_per_lead

    from campaign c
    left join member_summary ms
        on ms.crm_campaign_key = c.crm_campaign_key
    left join lead_summary ls
        on ls.crm_campaign_key = c.crm_campaign_key
    left join influence_summary isum
        on isum.crm_campaign_key = c.crm_campaign_key

)

select * from final
