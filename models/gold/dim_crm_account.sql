{{ config(materialized = 'table') }}

-- Salesforce's view of each account (current version). Customer master attributes stay on DIM_CUSTOMER; this carries the CRM side.

with account as (

    select a.*
    from {{ ref('silver_sfdc_account') }} a
    where a.__END_AT is null
      and a.IsDeleted = false

),

crm_user as (

    select u.Id
    from {{ ref('silver_sfdc_user') }} u

),

final as (

    select

          {{ generate_surrogate_key(['a.Id', "'SFDC'"]) }} as crm_account_key
        , a.Id as sfdc_account_id
        , acm.customer_key
        , acm.customer_match_source
        , a.Name as account_name
        , case
            when u.Id is not null then {{ generate_surrogate_key(['a.OwnerId', "'SFDC'"]) }}
            else cast({{ unknown_member_key() }} as bigint)
          end as owner_user_key
        , nullif(trim(a.Inside_Sales_Group__c), '') as inside_sales_rep
        , nullif(trim(a.Account_Specialist__c), '') as account_specialist
        , nullif(trim(a.Program_Manager__c), '') as program_manager
        , nullif(trim(a.Territory__c), '') as territory
        , a.Type as account_type
        , a.Account_Status__c as account_status
        , a.Active__c as is_active
        , coalesce(a.Type = 'Test', false) as is_test_account
        , a.Customer_Group__c as customer_group
        , a.DSO_Status__c as dso_status_code
        , a.DSO_Member__c as is_dso_member
        , a.TSD_Member__c as is_tsd_member
        , coalesce(a.Tippi_Toes__c, false) as is_tippi_toes
        , coalesce(a.TSDA_Franchise__c, false) as is_tsda_franchise
        , nullif(trim(a.Partnerships__c), '') as partnerships
        , nullif(trim(a.Other_Associations__c), '') as other_associations
        , nullif(trim(a.Genra__c), '') as dance_genres
        , nullif(trim(a.Store_Type__c), '') as store_type
        , a.Enrollment__c as enrollment
        , a.StudioCity__c as studio_city
        , a.StudioState__c as studio_state
        , a.StudioPostalCode__c as studio_postal_code
        , a.StudioCountry__c as studio_country
        , cast(from_utc_timestamp(a.CreatedDate, 'America/Chicago') as date) as account_created_date
        , a.ParentId as sfdc_parent_account_id
        , 'silver_sfdc_account' as record_source
        , {{ audit_columns() }}

    from account a
    left join {{ ref('v_crm_account_customer_map') }} acm
        on acm.sfdc_account_id = a.Id
    left join crm_user u
        on u.Id = a.OwnerId

)

select * from final
