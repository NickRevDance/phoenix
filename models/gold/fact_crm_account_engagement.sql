{{ config(materialized = 'table') }}

-- Current-state snapshot, one row per Salesforce account, rebuilt each run (as_of_date = run date).
-- Contact = a person's call, email or meeting (is_automated = false, owner is an Internal user). Orders come from FACT_SALES_INVOICE (D365/BigCommerce), marketing email from the source-agnostic staging model.

with account as (

    select
          a.crm_account_key
        , a.sfdc_account_id
        , a.customer_key
        , a.owner_user_key
        , a.is_test_account
    from {{ ref('dim_crm_account') }} a

),

activity as (

    select
          f.sfdc_account_id
        , f.owner_user_key
        , f.activity_channel
        , f.is_automated
        , f.activity_date
        , u.user_category
    from {{ ref('fact_crm_activity') }} f
    left join {{ ref('dim_crm_user') }} u
        on u.user_key = f.owner_user_key
    where f.sfdc_account_id is not null
      and f.activity_date <= current_date()

),

contact_summary as (

    select
          ac.sfdc_account_id
        , max(ac.activity_date) as last_contact_date
        , max(case when ac.owner_user_key = a.owner_user_key then ac.activity_date end) as last_owner_contact_date
        , max(case when ac.activity_channel = 'Call' then ac.activity_date end) as last_call_date
        , max(case when ac.activity_channel = 'Email' then ac.activity_date end) as last_email_date
        , max(case when ac.activity_channel = 'Meeting' then ac.activity_date end) as last_meeting_date
        , count_if(ac.activity_date > date_sub(current_date(), 30)) as contacts_30d
        , count_if(ac.activity_date > date_sub(current_date(), 90)) as contacts_90d
        , count_if(ac.activity_date > date_sub(current_date(), 365)) as contacts_365d
        , count_if(ac.activity_channel = 'Call' and ac.activity_date > date_sub(current_date(), 90)) as calls_90d
    from activity ac
    inner join account a
        on a.sfdc_account_id = ac.sfdc_account_id
    where ac.is_automated = false
      and ac.user_category = 'Internal'
      and ac.activity_channel in ('Call', 'Email', 'Meeting')
    group by ac.sfdc_account_id

),

marketing_summary as (

    select
          me.sfdc_account_id
        , max(case when me.event_type = 'Opened' then me.event_date end) as last_marketing_email_opened_date
        , count_if(me.event_type = 'Sent' and me.event_date > date_sub(current_date(), 90)) as marketing_emails_sent_90d
        , count_if(me.event_type = 'Opened' and me.event_date > date_sub(current_date(), 90)) as marketing_emails_opened_90d
    from {{ ref('silver_stage_marketing_email_event') }} me
    where me.sfdc_account_id is not null
      and me.event_date <= current_date()
    group by me.sfdc_account_id

),

case_summary as (

    select
          c.sfdc_account_id
        , count_if(not c.is_closed) as open_case_count
        , count_if(c.is_stale_open) as stale_open_case_count
        , count_if(c.created_date > date_sub(current_date(), 365)) as cases_365d
        , max(c.created_date) as last_case_date
    from {{ ref('fact_case') }} c
    where c.sfdc_account_id is not null
    group by c.sfdc_account_id

),

opportunity_summary as (

    select
          o.sfdc_account_id
        , count_if(not o.is_closed) as open_opportunity_count
        , {{ amount('sum(case when not o.is_closed then o.amount end)') }} as open_pipeline_amount
        , count_if(not o.is_closed and o.close_date < current_date()) as past_due_opportunity_count
    from {{ ref('fact_opportunity') }} o
    group by o.sfdc_account_id

),

event_summary as (

    select
          m.sfdc_account_id
        , count(distinct case when coalesce(c.start_date, m.added_date) > date_sub(current_date(), 365) then c.crm_campaign_key end) as events_attended_365d
        , max(coalesce(c.start_date, m.added_date)) as last_event_date
        , max_by(c.campaign_name, coalesce(c.start_date, m.added_date)) as last_event_name
    from {{ ref('fact_campaign_member') }} m
    inner join {{ ref('dim_crm_campaign') }} c
        on c.crm_campaign_key = m.crm_campaign_key
    where c.campaign_type in ('Event', 'Owned Event', 'Partnership & Event')
      and m.sfdc_account_id is not null
    group by m.sfdc_account_id

),

order_summary as (

    select
          i.customer_key
        , max(i.order_date) as last_order_date
        , max(i.invoice_date) as last_invoice_date
        , count(distinct case when i.order_date > date_sub(current_date(), 365) then i.order_id end) as orders_365d
        , {{ amount('sum(case when i.invoice_date > date_sub(current_date(), 365) then i.net_sales_amount_usd end)') }} as net_sales_usd_365d
    from {{ ref('fact_sales_invoice') }} i
    where i.customer_key > 0
      and not coalesce(i.is_return_flag, false)
      and not coalesce(i.is_intercompany_flag, false)
    group by i.customer_key

),

final as (

    select

          current_date() as as_of_date
        , a.crm_account_key
        , a.sfdc_account_id
        , a.customer_key
        , a.owner_user_key
        , a.is_test_account
        , cs.last_contact_date
        , cs.last_owner_contact_date
        , cs.last_call_date
        , cs.last_email_date
        , cs.last_meeting_date
        , datediff(current_date(), cs.last_contact_date) as days_since_last_contact
        , coalesce(cs.contacts_30d, 0) as contacts_30d
        , coalesce(cs.contacts_90d, 0) as contacts_90d
        , coalesce(cs.contacts_365d, 0) as contacts_365d
        , coalesce(cs.calls_90d, 0) as calls_90d
        , ms.last_marketing_email_opened_date
        , coalesce(ms.marketing_emails_sent_90d, 0) as marketing_emails_sent_90d
        , coalesce(ms.marketing_emails_opened_90d, 0) as marketing_emails_opened_90d
        , coalesce(ks.open_case_count, 0) as open_case_count
        , coalesce(ks.stale_open_case_count, 0) as stale_open_case_count
        , coalesce(ks.cases_365d, 0) as cases_365d
        , ks.last_case_date
        , coalesce(os.open_opportunity_count, 0) as open_opportunity_count
        , coalesce(os.open_pipeline_amount, 0) as open_pipeline_amount
        , coalesce(os.past_due_opportunity_count, 0) as past_due_opportunity_count
        , coalesce(es.events_attended_365d, 0) as events_attended_365d
        , es.last_event_date
        , es.last_event_name
        , os2.last_order_date
        , os2.last_invoice_date
        , datediff(current_date(), os2.last_order_date) as days_since_last_order
        , coalesce(os2.orders_365d, 0) as orders_365d
        , coalesce(os2.net_sales_usd_365d, 0) as net_sales_usd_365d
        , 'fact_crm_activity, silver_stage_marketing_email_event, fact_case, fact_opportunity, fact_campaign_member, fact_sales_invoice' as record_source
        , {{ audit_columns() }}

    from account a
    left join contact_summary cs
        on cs.sfdc_account_id = a.sfdc_account_id
    left join marketing_summary ms
        on ms.sfdc_account_id = a.sfdc_account_id
    left join case_summary ks
        on ks.sfdc_account_id = a.sfdc_account_id
    left join opportunity_summary os
        on os.sfdc_account_id = a.sfdc_account_id
    left join event_summary es
        on es.sfdc_account_id = a.sfdc_account_id
    left join order_summary os2
        on os2.customer_key = a.customer_key

)

select * from final
