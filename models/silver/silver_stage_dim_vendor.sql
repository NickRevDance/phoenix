with vendor_base as (

    select

          v.ACCOUNTNUM as vendor_id
        , 'D365'       as source_system
        , dp.NAME      as vendor_name
        , v.VENDGROUP  as vendor_group
        , v.PAYMTERMID as payment_terms
        , v.CURRENCY   as default_currency_code
        , v.DLVTERM    as default_incoterm_code
        , v.BLOCKED    as blocked_code
        , dp.LOGISTICSELECTRONICADDRESS_EMAIL_LOCATOR as primary_contact_email
        , dp.LOGISTICSELECTRONICADDRESS_PHONE_LOCATOR as primary_contact_phone
        , dp.PARTYNUMBER as d365_party_number, case
            when v.BLOCKED = 0 then 'Active'
            when v.BLOCKED = 1 then 'Suspended'
            when v.BLOCKED = 2 then 'Blocked'
            else 'Prospective'
          end as vendor_status -- best-effort mapping off VendTable.BLOCKED; full spec logic needs FACT_PURCHASE_ORDER activity + approval-workflow data not yet available, validate with Ops

    from {{ ref('silver_d365_vendor_table') }} v
    left join {{ ref('silver_d365_dir_party') }} dp
        on v.PARTYFIELD = dp.RECID

    -- NEEDS CONFIRMATION (Ops/Merchandising, spec Open Decision #1): excludes VENDGROUP
    -- NIM/Customer/Employee -- non-supplier AP payees, confirmed via live data 2026-09-02
    -- (NIM sampled 15/15 dance-studio/test records). Remaining groups still mix real
    -- suppliers with individuals and service vendors -- needs a manual allow-list to finish.
    where v.VENDGROUP not in ('NIM', 'Customer', 'Employee')

),

final as (

    select

        -- Surrogate PK: derived only from the business key so it stays
        -- stable across future SCD2 versions of the same vendor.
          xxhash64(b.vendor_id, b.source_system) as vendor_key

        , b.vendor_id
        , b.source_system
        , b.vendor_name
        , case when b.vendor_name is not null then split(b.vendor_name, ' ')[0] end as vendor_short_name

        , cast(null as string) as vendor_type  -- Source once available: derived from silver_d365_vendor_table.VENDGROUP and/or a manual seed file -- business rule TBD, spec Open Decision #1, validate with Ops/Merchandising
        , cast(null as string) as vendor_subtype  -- Source once available: manual classification -- Phase 2 enrichment, no source yet
        , b.vendor_group
        , cast(null as string) as vendor_category  -- Source once available: manual classification seed file reviewed with Merchandising -- Phase 2, no source yet

        , cast(null as string) as primary_contact_name  -- Source once available: D365 DirPartyContactInfoView -- not yet ingested via BYOD
        , b.primary_contact_email    -- party-level email off DirPartyTable; proxy for a named contact's email until DirPartyContactInfoView is sourced
        , b.primary_contact_phone    -- party-level phone off DirPartyTable; same caveat as primary_contact_email
        , cast(null as string) as vendor_website  -- Source once available: silver_d365_dir_party.LOGISTICSELECTRONICADDRESS_URL_LOCATOR (already populated on the source) -- Phase 2 per spec field catalog, not wired yet

        , cast(null as string) as address_line_1  -- Source once available: D365 LogisticsPostalAddress -- not yet ingested via BYOD, see [[dbt_sources_reference]]
        , cast(null as string) as address_line_2  -- Source once available: D365 LogisticsPostalAddress -- not yet ingested via BYOD
        , cast(null as string) as city  -- Source once available: D365 LogisticsPostalAddress -- not yet ingested via BYOD
        , cast(null as string) as state_province  -- Source once available: D365 LogisticsPostalAddress -- not yet ingested via BYOD
        , cast(null as string) as postal_code  -- Source once available: D365 LogisticsPostalAddress -- not yet ingested via BYOD
        , cast(null as string) as country_code  -- Source once available: D365 LogisticsPostalAddress.CountryRegionId -- not yet ingested via BYOD
        , cast(null as bigint) as country_key  -- Source once available: lookup against DIM_COUNTRY once country_code is sourced -- DIM_COUNTRY doesn't exist in this project yet either
        , cast(null as string) as geo_region  -- Source once available: derived from country_code using the DIM_CUSTOMER/DIM_WAREHOUSE region mapping -- Phase 2, blocked on country_code

        , b.payment_terms         -- raw D365 PaymTermId code; no PaymTerm display-value table sourced yet
        , b.default_currency_code
        , b.default_incoterm_code
        , cast(null as string) as tax_id  -- Source once available: silver_d365_vendor_table.VATNUM (already populated on the source) -- Phase 2 per spec, masking/hashing rule undefined
        , cast(null as decimal(19,4)) as credit_limit  -- Source once available: silver_d365_vendor_table.CREDITMAX (already populated on the source) -- Phase 2 per spec, not wired yet

        , cast(null as int) as default_lead_time_days  -- Source once available: D365 InventItemPurchSetup or PurchLeadTime -- not yet ingested via BYOD

        , cast(null as string) as quality_rating  -- Source once available: manual maintenance or quality inspection data -- Phase 2, no source yet
        , cast(null as decimal(5,2)) as on_time_delivery_target_pct  -- Source once available: vendor scorecard target-setting process -- Phase 2, no source yet
        , cast(null as boolean) as is_preferred_vendor  -- Source once available: procurement strategy sign-off -- Phase 2, no source yet

        , cast(null as string) as compliance_status  -- Source once available: compliance/certification tracking process -- Phase 2, no source yet
        , cast(null as date) as compliance_expiry_date  -- Source once available: compliance/certification tracking process -- Phase 2, no source yet
        , cast(null as string) as country_of_origin_primary  -- Source once available: manufacturing/sourcing records -- Phase 2, no source yet

        , b.vendor_status

        , case
            when b.blocked_code = 0 then 1
            else 0
          end as active_flag -- per spec Derived Business Rule: active_flag = 1 when vendor_status = 'Active'

        , cast(null as date) as effective_start_date  -- Source once available: no vendor-relationship-start field in the current D365 BYOD extract
        , cast(null as date) as effective_end_date  -- NULL = active; no deactivation-date source wired yet

        , b.vendor_id   as d365_vendor_account
        , b.vendor_group as d365_vendor_group_id
        , b.d365_party_number

        /*, current_timestamp() as version_start_date -- initial load: treated as the first version for every vendor
        , cast(null as timestamp) as version_end_date -- NULL = current row
        , cast(1 as boolean) as is_current_row -- trivially true today -- becomes meaningful once SCD2 snapshot wiring lands
        , 'Initial load' as scd_change_reason*/

        , sha2(
            concat_ws('||',
                coalesce(b.vendor_name, ''),
                coalesce(b.vendor_group, ''),
                coalesce(b.payment_terms, ''),
                coalesce(b.default_currency_code, ''),
                coalesce(b.default_incoterm_code, ''),
                coalesce(b.vendor_status, '')
            ), 256
          ) as vendor_change_hash -- hashes the currently-populated Type 2 (history-tracked) attributes per the spec's SCD2 Tracking Plan; extend this list as null placeholders above get wired to real sources

        , current_timestamp() as etl_insert_datetime

    from vendor_base b

)

select * from final
