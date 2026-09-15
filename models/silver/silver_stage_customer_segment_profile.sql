with customer_current as (

    -- Reads the pre-gold snapshot, not {{ ref('dim_customer') }} -- DIM_CUSTOMER's
    -- own gold model joins back to DIM_CUSTOMER_SEGMENT for customer_segment_key,
    -- so sourcing from the gold table here would create a circular ref.
    select
          customer_key
        , customer_type
        , is_dso_member_flag
        , dso_membership_status
    from {{ ref('silver_snapshot_dim_customer') }}
    where effective_end_datetime is null

),

customer_activity as (

    select
          customer_key
        , max(invoice_date) as most_recent_order_date
    from {{ ref('fact_sales_invoice') }}
    group by customer_key

),

final as (

    select

          c.customer_key

        , c.customer_type  -- copied from DIM_CUSTOMER, system of record

        , cast(null as string) as customer_segment  -- Source once available: Salesforce CRM / derived logic -- not sourced, Phase 2 per spec

        , case
            when a.most_recent_order_date is null then null
            when datediff(current_date(), a.most_recent_order_date) <= 90 then 'New'
            when datediff(current_date(), a.most_recent_order_date) <= 365 then 'Active'
            when datediff(current_date(), a.most_recent_order_date) <= 548 then 'Lapsed'
            else 'Churned'
          end as lifecycle_stage  -- NEEDS CONFIRMATION: thresholds per spec section 9, business sign-off pending (section 11 Open Decision #2). "Reactivated" not derived here -- needs prior-state tracking this pass doesn't do.

        , cast(null as string) as customer_tier  -- Source once available: revenue/frequency tier -- Phase 2 per spec, thresholds TBD

        , cast(null as string) as loyalty_tier  -- Source once available: SiteVibes via Jitterbit -- Phase 2 per spec, not wired

        , c.is_dso_member_flag  -- copied from DIM_CUSTOMER, system of record -- null today, Salesforce not wired

        , c.dso_membership_status  -- copied from DIM_CUSTOMER -- Phase 2 per spec, null today

        , cast(null as boolean) as loyalty_enrolled_flag  -- Source once available: DIM_CUSTOMER.loyalty_enrolled_flag -- DIM_CUSTOMER doesn't carry this field yet despite being system of record per spec

        , cast(null as string) as purchase_frequency_band  -- Source once available: trailing 12mo order count -- Phase 2 per spec field catalog

        , cast(null as string) as avg_order_value_band  -- Source once available: trailing AOV vs. cohort -- Phase 2 per spec, banding logic TBD

        , cast(null as string) as channel_preference  -- Source once available: majority channel over trailing 12mo -- Phase 2 per spec field catalog

    from customer_current c
    left join customer_activity a
        on c.customer_key = a.customer_key

)

select * from final
