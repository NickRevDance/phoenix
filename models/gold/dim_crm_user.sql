{{ config(materialized = 'table') }}

with sfdc_user as (

    select

          {{ generate_surrogate_key(['u.Id', "'SFDC'"]) }} as user_key
        , u.Id as sfdc_user_id
        , u.Name as user_name
        , u.FirstName as first_name
        , u.LastName as last_name
        , u.Title as title
        , u.Department as department
        , u.Division as division
        , u.UserType as user_type
        , u.user_category
        , u.user_category = 'Internal' as is_internal_user
        , u.IsActive as is_active
        , case when u.ManagerId is not null then {{ generate_surrogate_key(['u.ManagerId', "'SFDC'"]) }} end as manager_user_key
        , m.Name as manager_name
        , u.ProfileId as sfdc_profile_id
        , u.UserRoleId as sfdc_user_role_id
        , cast(from_utc_timestamp(u.CreatedDate, 'America/Chicago') as date) as user_created_date
        , u.LastLoginDate as last_login_datetime

    from {{ ref('silver_sfdc_user') }} u
    left join {{ ref('silver_sfdc_user') }} m
        on m.Id = u.ManagerId

),

reserved as (

    select
          r.user_key
        , r.sfdc_user_id
        , r.user_name
        , cast(null as string) as first_name
        , cast(null as string) as last_name
        , cast(null as string) as title
        , cast(null as string) as department
        , cast(null as string) as division
        , cast(null as string) as user_type
        , r.user_category
        , false as is_internal_user
        , true as is_active
        , cast(null as bigint) as manager_user_key
        , cast(null as string) as manager_name
        , cast(null as string) as sfdc_profile_id
        , cast(null as string) as sfdc_user_role_id
        , cast(null as date) as user_created_date
        , cast(null as timestamp) as last_login_datetime
    from (
        values
              (cast({{ unknown_member_key() }} as bigint), 'UNKNOWN', 'Unknown User', 'Unknown')
            , (cast({{ default_member_key() }} as bigint), 'QUEUE', 'Queue (no user owner)', 'Queue')
    ) as r(user_key, sfdc_user_id, user_name, user_category)

),

final as (

    select
          s.*
        , 'silver_sfdc_user' as record_source
        , {{ audit_columns() }}
    from sfdc_user s

    union all

    select
          r.*
        , 'reserved_member' as record_source
        , {{ audit_columns() }}
    from reserved r

)

select * from final
