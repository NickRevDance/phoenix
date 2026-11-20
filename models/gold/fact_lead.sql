{{ config(materialized = 'table') }}

with lead_base as (

    select
          l.*
        , cast(from_utc_timestamp(l.CreatedDate, 'America/Chicago') as date) as created_date
    from {{ ref('silver_sfdc_lead') }} l
    where l.IsDeleted = false

),

crm_user as (

    select u.Id
    from {{ ref('silver_sfdc_user') }} u

),

campaign as (

    select c.Id
    from {{ ref('silver_sfdc_campaign') }} c
    where c.IsDeleted = false

),

pipeline_opportunity as (

    select o.sfdc_opportunity_id
    from {{ ref('fact_opportunity') }} o

),

final as (

    select

          {{ generate_surrogate_key(['l.Id', "'SFDC'"]) }} as lead_key
        , l.Id as sfdc_lead_id
        , case
            when left(l.OwnerId, 3) = '00G' then cast({{ default_member_key() }} as bigint)
            when u.Id is not null then {{ generate_surrogate_key(['l.OwnerId', "'SFDC'"]) }}
            else cast({{ unknown_member_key() }} as bigint)
          end as owner_user_key
        , case
            when l.first_campaign_id is null then cast({{ default_member_key() }} as bigint)
            when c.Id is not null then {{ generate_surrogate_key(['l.first_campaign_id', "'SFDC'"]) }}
            else cast({{ unknown_member_key() }} as bigint)
          end as first_crm_campaign_key
        , l.LeadSource as lead_source
        , l.Status as lead_status
        , l.status_order
        , l.lead_outcome
        , l.IsConverted as is_converted
        , l.is_existing_customer_at_conversion
        , l.IsConverted and not coalesce(l.is_existing_customer_at_conversion, false) as is_new_customer_conversion
        , l.ConvertedOpportunityId is not null as is_converted_to_opportunity
        , case when l.IsConverted then coalesce(acm.customer_key, cast({{ unknown_member_key() }} as bigint)) end as converted_customer_key
        , l.ConvertedAccountId as sfdc_converted_account_id
        , case when po.sfdc_opportunity_id is not null then {{ generate_surrogate_key(['l.ConvertedOpportunityId', "'SFDC'"]) }} end as converted_opportunity_key
        , l.ConvertedOpportunityId as sfdc_converted_opportunity_id
        , l.Company as company_name
        , l.State as state_province
        , l.Country as country
        , l.CreatedDate as created_datetime
        , l.created_date
        , cast(date_format(l.created_date, 'yyyyMMdd') as int) as created_date_key
        , l.ConvertedDate as converted_date
        , cast(date_format(l.ConvertedDate, 'yyyyMMdd') as int) as converted_date_key
        , l.days_to_convert
        , 'silver_sfdc_lead' as record_source
        , {{ audit_columns() }}

    from lead_base l
    left join crm_user u
        on u.Id = l.OwnerId
    left join campaign c
        on c.Id = l.first_campaign_id
    left join {{ ref('v_crm_account_customer_map') }} acm
        on acm.sfdc_account_id = l.ConvertedAccountId
    left join pipeline_opportunity po
        on po.sfdc_opportunity_id = l.ConvertedOpportunityId

)

select * from final
