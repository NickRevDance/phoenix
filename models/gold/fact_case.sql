{{ config(materialized = 'table') }}

with sfdc_case as (

    select c.*
    from {{ ref('silver_sfdc_case') }} c
    where c.__END_AT is null
      and c.IsDeleted = false

),

email_summary as (

    select
          e.ParentId
        , count_if(e.Incoming) as inbound_email_count
        , count_if(not e.Incoming) as outbound_email_count
        , min(case when not e.Incoming then e.MessageDate end) as first_outbound_email_datetime
    from {{ ref('silver_sfdc_email_message') }} e
    where left(e.ParentId, 3) = '500'
    group by e.ParentId

),

crm_user as (

    select u.Id
    from {{ ref('silver_sfdc_user') }} u

),

shaped as (

    select

          c.*
        , es.inbound_email_count
        , es.outbound_email_count
        , case when es.first_outbound_email_datetime >= c.CreatedDate then es.first_outbound_email_datetime end as first_response_datetime
        , cast(from_utc_timestamp(c.CreatedDate, 'America/Chicago') as date) as created_date
        , cast(from_utc_timestamp(c.ClosedDate, 'America/Chicago') as date) as closed_date

    from sfdc_case c
    left join email_summary es
        on es.ParentId = c.Id

),

final as (

    select

          {{ generate_surrogate_key(['c.Id', "'SFDC'"]) }} as case_key
        , c.Id as sfdc_case_id
        , c.CaseNumber as case_number
        , case when c.AccountId is not null then coalesce(acm.customer_key, cast({{ unknown_member_key() }} as bigint)) end as customer_key
        , case when c.AccountId is not null then {{ generate_surrogate_key(['c.AccountId', "'SFDC'"]) }} end as crm_account_key
        , c.AccountId as sfdc_account_id
        , c.ContactId as sfdc_contact_id
        , case
            when left(c.OwnerId, 3) = '00G' then cast({{ default_member_key() }} as bigint)
            when u.Id is not null then {{ generate_surrogate_key(['c.OwnerId', "'SFDC'"]) }}
            else cast({{ unknown_member_key() }} as bigint)
          end as owner_user_key
        , c.Status as case_status
        , c.IsClosed as is_closed
        , c.IsClosedOnCreate as is_closed_on_create
        , c.Origin as case_origin
        , c.Type as case_type
        , c.Reason as case_reason
        , c.Priority as case_priority
        , c.Disposition__c as case_disposition
        , c.Conclusion__c as case_conclusion
        , c.Product_Name__c as product_name
        , c.CreatedDate as created_datetime
        , c.created_date
        , cast(date_format(c.created_date, 'yyyyMMdd') as int) as created_date_key
        , c.ClosedDate as closed_datetime
        , c.closed_date
        , cast(date_format(c.closed_date, 'yyyyMMdd') as int) as closed_date_key
        , case when c.IsClosed then round((unix_timestamp(c.ClosedDate) - unix_timestamp(c.CreatedDate)) / 3600.0, 2) end as hours_to_close
        , case when not c.IsClosed then datediff(current_date(), c.created_date) end as days_open
        , not c.IsClosed and datediff(current_date(), c.created_date) > {{ var('crm_stale_case_days', 90) }} as is_stale_open
        , coalesce(c.inbound_email_count, 0) as inbound_email_count
        , coalesce(c.outbound_email_count, 0) as outbound_email_count
        , c.first_response_datetime
        , round((unix_timestamp(c.first_response_datetime) - unix_timestamp(c.CreatedDate)) / 3600.0, 2) as hours_to_first_response
        , 'silver_sfdc_case' as record_source
        , {{ audit_columns() }}

    from shaped c
    left join {{ ref('v_crm_account_customer_map') }} acm
        on acm.sfdc_account_id = c.AccountId
    left join crm_user u
        on u.Id = c.OwnerId

)

select * from final
