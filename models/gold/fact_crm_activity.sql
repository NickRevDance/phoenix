{{ config(materialized = 'table') }}

-- Tasks and Events in one fact, from crm_activity_start_date (default 2020-01-01) on. Includes service (case email) and integration-logged
-- activity; filter on the owner's user_category or what_object_type.

with activity as (

    select
          t.Id
        , 'Task' as activity_object
        , t.TaskSubtype as activity_subtype
        , t.Type as activity_type
        , t.CallType as call_type
        , t.Status as activity_status
        , t.IsClosed as is_completed
        , t.OwnerId
        , t.AccountId
        , t.WhatId
        , t.what_object_type
        , t.WhoId
        , t.who_object_type
        , t.ActivityDate
        , t.CreatedDate
        , t.CallDurationInSeconds as call_duration_seconds
        , cast(null as int) as event_duration_minutes
        , t.activity_channel
        , t.is_automated
        , t.klaviyo_event
    from {{ ref('silver_sfdc_task') }} t
    where t.IsDeleted = false

    union all

    select
          e.Id
        , 'Event' as activity_object
        , e.EventSubtype as activity_subtype
        , e.Type as activity_type
        , cast(null as string) as call_type
        , cast(null as string) as activity_status
        , coalesce(e.EndDateTime, e.ActivityDateTime) <= current_timestamp() as is_completed
        , e.OwnerId
        , e.AccountId
        , e.WhatId
        , e.what_object_type
        , e.WhoId
        , e.who_object_type
        , e.ActivityDate
        , e.CreatedDate
        , cast(null as int) as call_duration_seconds
        , e.DurationInMinutes as event_duration_minutes
        , e.activity_channel
        , e.is_automated
        , cast(null as string) as klaviyo_event
    from {{ ref('silver_sfdc_event') }} e
    where e.IsDeleted = false

),

crm_user as (

    select u.Id
    from {{ ref('silver_sfdc_user') }} u

),

pipeline_opportunity as (

    select o.sfdc_opportunity_id
    from {{ ref('fact_opportunity') }} o

),

lead_ids as (

    select l.Id
    from {{ ref('silver_sfdc_lead') }} l
    where l.IsDeleted = false

),

shaped as (

    select
          a.*
        , cast(from_utc_timestamp(a.CreatedDate, 'America/Chicago') as date) as created_date
        , coalesce(a.ActivityDate, cast(from_utc_timestamp(a.CreatedDate, 'America/Chicago') as date)) as activity_date
    from activity a
    where coalesce(a.ActivityDate, cast(from_utc_timestamp(a.CreatedDate, 'America/Chicago') as date))
          >= date('{{ var("crm_activity_start_date", "2020-01-01") }}')

),

final as (

    select

          {{ generate_surrogate_key(['a.Id', "'SFDC'"]) }} as activity_key
        , a.Id as sfdc_activity_id
        , a.activity_object
        , a.activity_channel
        , a.is_automated
        , a.klaviyo_event
        , a.activity_subtype
        , a.activity_type
        , a.call_type
        , a.activity_status
        , a.is_completed
        , case
            when left(a.OwnerId, 3) = '00G' then cast({{ default_member_key() }} as bigint)
            when u.Id is not null then {{ generate_surrogate_key(['a.OwnerId', "'SFDC'"]) }}
            else cast({{ unknown_member_key() }} as bigint)
          end as owner_user_key
        , case when a.AccountId is not null then coalesce(acm.customer_key, cast({{ unknown_member_key() }} as bigint)) end as customer_key
        , a.AccountId as sfdc_account_id
        , a.what_object_type
        , a.WhatId as sfdc_what_id
        , a.who_object_type
        , a.WhoId as sfdc_who_id
        , case when po.sfdc_opportunity_id is not null then {{ generate_surrogate_key(['a.WhatId', "'SFDC'"]) }} end as opportunity_key
        , case when li.Id is not null then {{ generate_surrogate_key(['a.WhoId', "'SFDC'"]) }} end as lead_key
        , a.activity_date
        , coalesce(dad.date_key, {{ unknown_member_key() }}) as activity_date_key  -- dates past DIM_DATE's range go to -1
        , a.ActivityDate is null as is_activity_date_defaulted
        , a.CreatedDate as created_datetime
        , a.created_date
        , coalesce(dcd.date_key, {{ unknown_member_key() }}) as created_date_key
        , a.call_duration_seconds
        , a.event_duration_minutes
        , 'silver_sfdc_task, silver_sfdc_event' as record_source
        , {{ audit_columns() }}

    from shaped a
    left join crm_user u
        on u.Id = a.OwnerId
    left join {{ ref('v_crm_account_customer_map') }} acm
        on acm.sfdc_account_id = a.AccountId
    left join pipeline_opportunity po
        on po.sfdc_opportunity_id = a.WhatId
    left join lead_ids li
        on li.Id = a.WhoId
    left join {{ ref('dim_date') }} dad
        on dad.date_key = cast(date_format(a.activity_date, 'yyyyMMdd') as int)
    left join {{ ref('dim_date') }} dcd
        on dcd.date_key = cast(date_format(a.created_date, 'yyyyMMdd') as int)

)

select * from final
