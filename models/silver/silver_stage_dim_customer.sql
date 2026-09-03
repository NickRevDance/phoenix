with d365_customer_base as (

    select

          c.ACCOUNTNUM   as customer_id
        , 'D365'         as source_system
        , c.ACCOUNTNUM   as d365_customer_id
        , cast(null as string) as bc_customer_id
        , cast(null as string) as sf_customer_id  -- Source once available: Salesforce customer source not yet wired -- Phase 2 per spec
        , c.ACCOUNTNUM   as customer_code  -- no distinct customer-code field on the native CustTable extract, separate from the account number

        , dp.NAME        as customer_name
        , cast(null as string) as first_name  -- CustTable/DirPartyTable BYOD extracts carry no person/organization discriminator to split a name into parts
        , cast(null as string) as last_name
        , dp.NAME        as company_name  -- D365 CustTable = wholesale/B2B accounts per spec Source Systems section; treated as an org name
        , dp.LOGISTICSELECTRONICADDRESS_EMAIL_LOCATOR as email
        , dp.LOGISTICSELECTRONICADDRESS_PHONE_LOCATOR as phone_primary

        , cast(null as string) as ship_to_address_line_1  -- Source once available: D365 LogisticsPostalAddress -- not yet ingested via BYOD, see dbt_sources_reference
        , cast(null as string) as ship_to_address_line_2  -- Source once available: D365 LogisticsPostalAddress
        , cast(null as string) as ship_to_city  -- Source once available: D365 LogisticsPostalAddress
        , cast(null as string) as ship_to_state_province  -- Source once available: D365 LogisticsPostalAddress
        , cast(null as string) as ship_to_postal_code  -- Source once available: D365 LogisticsPostalAddress
        , cast(null as string) as ship_to_country_code  -- Source once available: D365 LogisticsPostalAddress.CountryRegionId
        , cast(null as string) as bill_to_address_line_1  -- Source once available: D365 LogisticsPostalAddress
        , cast(null as string) as bill_to_city  -- Source once available: D365 LogisticsPostalAddress
        , cast(null as string) as bill_to_state_province  -- Source once available: D365 LogisticsPostalAddress
        , cast(null as string) as bill_to_postal_code  -- Source once available: D365 LogisticsPostalAddress
        , cast(null as string) as bill_to_country_code  -- Source once available: D365 LogisticsPostalAddress

        , 'B2B' as customer_type  -- NEEDS CONFIRMATION: D365 CustTable = wholesale/B2B accounts per spec Source Systems section; no PersonTypeCode/storefront on this source to refine further -- business rule TBD, spec Recommended Next Steps #3
        , cast(null as string) as storefront_code  -- D365 accounts aren't ecommerce storefront customers

        , c.CURRENCY     as currency_code
        , c.PAYMTERMID   as d365_payment_terms  -- already available on CustTable; still nulled out below -- Phase 2 per spec
        , c.CREDITMAX    as d365_credit_limit_amount  -- already available on CustTable; still nulled out below -- Phase 2 per spec

        , case
            when c.BLOCKED = 0 then 'Active'
            else 'Suspended'
          end as customer_status  -- NEEDS CONFIRMATION: best-effort mapping off CustTable.BLOCKED; full Active/Inactive/Closed logic needs order-activity thresholds TBD with business (spec section 9) -- no sales fact table exists in this project yet to derive them from

        , c.CREATEDDATE  as account_created_date

    from {{ ref('silver_d365_customer_table') }} c
    left join {{ ref('silver_d365_dir_party') }} dp
        on c.PARTY = dp.RECID

),

bc_customer_dedup as (

    -- bc.customer_header carries 54 duplicate customer_id values (30,261
    -- rows / 30,207 distinct ids, confirmed live 2026-09-03) -- keep the
    -- most-recently-modified row per id so customer_id is a safe grain key.
    select
        bc.*
        , row_number() over (
            partition by bc.customer_id
            order by bc.date_modified desc, bc.date_created desc
          ) as rn
    from {{ ref('silver_bc_customer') }} bc

),

bc_customer_base as (

    select

          cast(bc.customer_id as string) as customer_id
        , 'BigCommerce'  as source_system
        , cast(null as string) as d365_customer_id
        , cast(bc.customer_id as string) as bc_customer_id
        , cast(null as string) as sf_customer_id  -- Source once available: Salesforce customer source not yet wired -- Phase 2 per spec
        , cast(null as string) as customer_code  -- no distinct customer-code field on bc.customer_header beyond customer_id itself

        , case
            when nullif(trim(bc.company), '') is not null then bc.company
            else trim(concat(coalesce(bc.first_name, ''), ' ', coalesce(bc.last_name, '')))
          end as customer_name
        , bc.first_name  as first_name
        , bc.last_name   as last_name
        , bc.company     as company_name
        , bc.email       as email
        , bc.phone       as phone_primary

        , cast(null as string) as ship_to_address_line_1  -- Source once available: BigCommerce address book is a separate per-customer/per-order entity -- not yet ingested via BYOD
        , cast(null as string) as ship_to_address_line_2  -- Source once available: BigCommerce address book
        , cast(null as string) as ship_to_city  -- Source once available: BigCommerce address book
        , cast(null as string) as ship_to_state_province  -- Source once available: BigCommerce address book
        , cast(null as string) as ship_to_postal_code  -- Source once available: BigCommerce address book
        , cast(null as string) as ship_to_country_code  -- Source once available: BigCommerce address book
        , cast(null as string) as bill_to_address_line_1  -- Source once available: BigCommerce address book
        , cast(null as string) as bill_to_city  -- Source once available: BigCommerce address book
        , cast(null as string) as bill_to_state_province  -- Source once available: BigCommerce address book
        , cast(null as string) as bill_to_postal_code  -- Source once available: BigCommerce address book
        , cast(null as string) as bill_to_country_code  -- Source once available: BigCommerce address book

        , case
            when nullif(trim(bc.company), '') is not null then 'B2B'
            else 'B2C'
          end as customer_type  -- NEEDS CONFIRMATION: a populated company name is treated as B2B, else B2C -- business rule TBD, spec Recommended Next Steps #3. Live data check 2026-09-03: 30,144 of 30,261 bc.customer_header rows (99.6%) have a non-blank company (mostly dance-studio names), so this classifies nearly all BigCommerce customers as B2B -- contradicts the spec's framing of BigCommerce as "B2C and some B2B" (spec section 2). Worth confirming with Business before relying on this split.
        , bc.store as storefront_code  -- BC storefront: US, CA, TT

        , cast(null as string) as currency_code  -- Source once available: currency is transaction-level in BigCommerce, no per-customer currency column on bc.customer_header
        , cast(null as string) as d365_payment_terms  -- not applicable -- BigCommerce customers are not on D365 payment terms
        , cast(null as decimal(19,4)) as d365_credit_limit_amount  -- not applicable -- BigCommerce customers do not carry a D365 credit limit

        , 'Active' as customer_status  -- NEEDS CONFIRMATION: bc.customer_header carries no account-status column; full Active/Inactive/Closed logic needs order-activity thresholds TBD with business (spec section 9)

        , bc.date_created as account_created_date

    from bc_customer_dedup bc
    where bc.rn = 1

),

combined as (

    select * from d365_customer_base
    union all
    select * from bc_customer_base

),

final as (

    select

        -- Surrogate PK: derived only from the business key so it stays
        -- stable across future SCD2 versions of the same customer. No
        -- cross-system entity resolution yet -- see customer_id note below.
          xxhash64(c.customer_id, c.source_system) as customer_key

        , c.customer_id  -- NEEDS CONFIRMATION: Master ID strategy is still open per spec section 10 #1 -- this is each source system's own native ID, not a resolved cross-system identity. A customer who exists in both D365 and BigCommerce currently produces two DIM_CUSTOMER rows.
        , c.source_system
        , c.d365_customer_id
        , c.bc_customer_id
        , c.sf_customer_id
        , c.customer_code

        , c.customer_name
        , c.first_name
        , c.last_name
        , c.company_name
        , sha2(lower(trim(c.email)), 256) as email_hash  -- never store raw email in the gold layer, per spec section 9
        , case
            when c.email is not null and instr(c.email, '@') > 0
            then substring(c.email, instr(c.email, '@') + 1)
          end as email_domain
        , c.phone_primary

        , c.ship_to_address_line_1
        , c.ship_to_address_line_2
        , c.ship_to_city
        , c.ship_to_state_province
        , c.ship_to_postal_code
        , c.ship_to_country_code
        , cast(null as bigint) as ship_to_country_key  -- Source once available: lookup against DIM_COUNTRY -- DIM_COUNTRY doesn't exist in this project yet

        , c.bill_to_address_line_1
        , c.bill_to_city
        , c.bill_to_state_province
        , c.bill_to_postal_code
        , c.bill_to_country_code

        , c.customer_type
        , cast(null as string) as person_type_code  -- Source once available: no person/organization-type discriminator on silver_d365_customer_table or silver_d365_dir_party -- business rule TBD, spec Recommended Next Steps #3
        , cast(null as string) as person_type_desc  -- Source once available: same as person_type_code
        , c.storefront_code
        , cast(null as bigint) as sales_channel_key  -- Source once available: DIM_SALES_CHANNEL FK -- Phase 2 per spec, DIM_SALES_CHANNEL doesn't exist in this project yet

        , cast(null as bigint) as customer_segment_key  -- Source once available: DIM_CUSTOMER_SEGMENT lookup -- spec recommends building it alongside this table (section 10 #5), not built in this delivery
        , cast(null as boolean) as is_dso_member_flag  -- Source once available: Salesforce DSO / Member Gate -- requires Salesforce CRM integration per spec section 7, not wired yet
        , cast(null as string) as dso_membership_status  -- Source once available: Salesforce Member Gate -- Phase 2 per spec

        , cast(null as boolean) as is_loyalty_eligible_flag  -- v1.2: NULL until the loyalty exclusion list source is identified by Marketing -- spec section 11 (EDW-80); not defaulted to eligible
        , cast(null as string) as loyalty_exclusion_reason  -- v1.2: same open dependency as is_loyalty_eligible_flag -- spec section 11

        , c.customer_status
        , cast(null as boolean) as is_credit_hold_flag  -- Source once available: no credit-hold column identified on silver_d365_customer_table (CustTable BYOD extract) or the legacy analytics.d_customer table -- confirm source with Ops
        , cast(null as boolean) as is_tax_exempt_flag  -- Phase 2 per spec
        , cast(null as string) as tax_exempt_certificate  -- Phase 2 per spec

        , c.currency_code
        , cast(null as string) as payment_terms  -- already available as d365_payment_terms above (CustTable.PAYMTERMID) -- Phase 2 per spec, phase boundary governs not data availability
        , cast(null as decimal(19,4)) as credit_limit_amount  -- already available as d365_credit_limit_amount above (CustTable.CREDITMAX) -- Phase 2 per spec

        , cast(null as date) as first_order_date  -- Source once available: derived from a sales fact table -- Phase 2 per spec, no FACT_SALES_INVOICE exists in this project yet
        , cast(null as date) as most_recent_order_date  -- Source once available: same as first_order_date
        , c.account_created_date
        , cast(date_format(c.account_created_date, 'yyyyMMdd') as int) as account_created_date_key

        , cast(null as string) as geo_region  -- Source once available: standard state-to-region mapping table -- Phase 2 per spec, no mapping table exists in this project yet
        , c.ship_to_state_province as geo_state_province
        , cast(null as string) as geo_metro_area  -- Phase 3 per spec

        -- Hashes only the Type 2 attributes that can actually change today
        -- (per the spec's SCD2 Tracking Plan) -- extend this list as null
        -- placeholders above get wired to real sources.
        , sha2(
            concat_ws('||',
                coalesce(c.customer_type, ''),
                coalesce(c.customer_status, '')
            ), 256
          ) as customer_change_hash

        , 'silver_stage_dim_customer' as record_source_table
        , current_timestamp() as etl_insert_datetime

    from combined c

)

select * from final
