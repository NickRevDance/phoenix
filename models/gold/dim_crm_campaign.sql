{{ config(materialized = 'table') }}

with campaign as (

    select

          {{ generate_surrogate_key(['c.Id', "'SFDC'"]) }} as crm_campaign_key
        , c.Id as sfdc_campaign_id
        , c.Name as campaign_name
        , c.Type as campaign_type
        , c.Status as campaign_status
        , c.IsActive as is_active
        , case when c.ParentId is not null then {{ generate_surrogate_key(['c.ParentId', "'SFDC'"]) }} end as parent_crm_campaign_key
        , p.Name as parent_campaign_name
        , c.StartDate as start_date
        , c.EndDate as end_date
        , {{ amount('c.BudgetedCost') }} as budgeted_cost
        , {{ amount('c.ActualCost') }} as actual_cost
        , {{ amount('c.ExpectedRevenue') }} as expected_revenue
        , cast(c.ExpectedResponse as double) as expected_response_pct
        , {{ generate_surrogate_key(['c.OwnerId', "'SFDC'"]) }} as owner_user_key
        , cast(from_utc_timestamp(c.CreatedDate, 'America/Chicago') as date) as campaign_created_date

    from {{ ref('silver_sfdc_campaign') }} c
    left join {{ ref('silver_sfdc_campaign') }} p
        on p.Id = c.ParentId
    where c.IsDeleted = false

),

reserved as (

    select
          r.crm_campaign_key
        , r.sfdc_campaign_id
        , r.campaign_name
        , cast(null as string) as campaign_type
        , cast(null as string) as campaign_status
        , true as is_active
        , cast(null as bigint) as parent_crm_campaign_key
        , cast(null as string) as parent_campaign_name
        , cast(null as date) as start_date
        , cast(null as date) as end_date
        , {{ amount('null') }} as budgeted_cost
        , {{ amount('null') }} as actual_cost
        , {{ amount('null') }} as expected_revenue
        , cast(null as double) as expected_response_pct
        , cast({{ unknown_member_key() }} as bigint) as owner_user_key
        , cast(null as date) as campaign_created_date
    from (
        values
              (cast({{ unknown_member_key() }} as bigint), 'UNKNOWN', 'Unknown Campaign')
            , (cast({{ default_member_key() }} as bigint), 'NONE', 'No Campaign')
    ) as r(crm_campaign_key, sfdc_campaign_id, campaign_name)

),

final as (

    select
          c.*
        , 'silver_sfdc_campaign' as record_source
        , {{ audit_columns() }}
    from campaign c

    union all

    select
          r.*
        , 'reserved_member' as record_source
        , {{ audit_columns() }}
    from reserved r

)

select * from final
