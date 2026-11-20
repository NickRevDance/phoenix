{{ config(materialized = 'view') }}

-- Salesforce Account to DIM_CUSTOMER: the D365 customer number first, then the BigCommerce customer id, else the -1 member.

with account as (

    select

          a.Id as sfdc_account_id
        , nullif(trim(a.StudioAccountNumber__c), '') as studio_account_number
        , nullif(trim(a.BC_Customer_Id__c), '') as bc_customer_id

    from {{ ref('silver_sfdc_account') }} a
    where a.__END_AT is null

),

d365_customer as (

    select
          c.customer_key
        , c.d365_customer_id
    from {{ ref('v_dim_customer_current') }} c
    where c.source_system = 'D365'

),

bc_customer as (

    select
          c.customer_key
        , c.customer_id
    from {{ ref('v_dim_customer_current') }} c
    where c.source_system = 'BigCommerce'

),

final as (

    select

          a.sfdc_account_id
        , coalesce(d.customer_key, b.customer_key, cast({{ unknown_member_key() }} as bigint)) as customer_key
        , case
            when d.customer_key is not null then 'D365'
            when b.customer_key is not null then 'BigCommerce'
            else 'Unmatched'
          end as customer_match_source
        , a.studio_account_number
        , a.bc_customer_id

    from account a
    left join d365_customer d
        on d.d365_customer_id = a.studio_account_number
    left join bc_customer b
        on b.customer_id = a.bc_customer_id

)

select * from final
