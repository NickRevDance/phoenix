{{ config(materialized = 'table') }}

with member as (

    select
          cm.*
        , cast(from_utc_timestamp(cm.CreatedDate, 'America/Chicago') as date) as added_date
    from {{ ref('silver_sfdc_campaign_member') }} cm
    where cm.IsDeleted = false

),

campaign as (

    select c.Id
    from {{ ref('silver_sfdc_campaign') }} c
    where c.IsDeleted = false

),

lead_ids as (

    select l.Id
    from {{ ref('silver_sfdc_lead') }} l
    where l.IsDeleted = false

),

final as (

    select

          {{ generate_surrogate_key(['m.Id', "'SFDC'"]) }} as campaign_member_key
        , m.Id as sfdc_campaign_member_id
        , case
            when c.Id is not null then {{ generate_surrogate_key(['m.CampaignId', "'SFDC'"]) }}
            else cast({{ unknown_member_key() }} as bigint)
          end as crm_campaign_key
        , m.Type as member_type
        , case when li.Id is not null then {{ generate_surrogate_key(['m.LeadId', "'SFDC'"]) }} end as lead_key
        , m.LeadId as sfdc_lead_id
        , m.ContactId as sfdc_contact_id
        , case when m.member_account_id is not null then coalesce(acm.customer_key, cast({{ unknown_member_key() }} as bigint)) end as customer_key
        , m.member_account_id as sfdc_account_id
        , m.Status as member_status
        , m.HasResponded as has_responded
        , m.LeadSource as lead_source
        , m.CreatedDate as added_datetime
        , m.added_date
        , cast(date_format(m.added_date, 'yyyyMMdd') as int) as added_date_key
        , m.FirstRespondedDate as first_responded_date
        , cast(date_format(m.FirstRespondedDate, 'yyyyMMdd') as int) as first_responded_date_key
        , 'silver_sfdc_campaign_member' as record_source
        , {{ audit_columns() }}

    from member m
    left join campaign c
        on c.Id = m.CampaignId
    left join lead_ids li
        on li.Id = m.LeadId
    left join {{ ref('v_crm_account_customer_map') }} acm
        on acm.sfdc_account_id = m.member_account_id

)

select * from final
