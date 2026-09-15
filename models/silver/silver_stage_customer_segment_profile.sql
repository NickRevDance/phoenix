with customer_current as (

    -- This model computes DIM_CUSTOMER_SEGMENT's inputs (customer_segment_key
    -- feeds back into DIM_CUSTOMER), so it is structurally upstream of
    -- DIM_CUSTOMER and must read the pre-gold snapshot here, not
    -- {{ ref('dim_customer') }} -- sourcing from the gold table would make
    -- DIM_CUSTOMER depend on its own output. This is the one model in the
    -- customer chain that has to know its position in the DAG; every fact
    -- table (fact_sales_invoice included, see its customer CTE) is free to
    -- ref('dim_customer') directly.
    select
          customer_key
        , customer_id
        , source_system
        , customer_type
        , is_dso_member_flag
        , dso_membership_status
    from {{ ref('silver_snapshot_dim_customer') }}
    where effective_end_datetime is null

),

customer_activity as (

    -- Order recency is computed directly off the raw D365 invoice silver
    -- tables here (same PARENTRECID = REC header relation fact_sales_invoice
    -- uses -- see its trans/jour join comment) rather than by aggregating
    -- {{ ref('fact_sales_invoice') }}. That's deliberate: it keeps this
    -- model's dependencies below fact_sales_invoice in the DAG, so
    -- fact_sales_invoice never has to avoid dim_customer to dodge a cycle
    -- back through here.
    select
          j.INVOICEACCOUNT as customer_id
        , max(t.INVOICEDATE) as most_recent_order_date
    from {{ ref('silver_d365_cust_invoice_trans') }} t
    inner join {{ ref('silver_d365_cust_invoice_jour') }} j
        on t.PARENTRECID = j.REC
    group by j.INVOICEACCOUNT

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
        on c.customer_id = a.customer_id
        and c.source_system = 'D365'  -- order history is D365-only, same scope limit as fact_sales_invoice's customer CTE; BigCommerce customers fall into the null/no-orders bucket below

)

select * from final
