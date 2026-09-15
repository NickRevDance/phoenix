{{ config(materialized = 'table') }}

with versioned as (

    select

          snap.*
        , row_number() over (
            partition by snap.purchase_order_entity_key
            order by snap.effective_start_datetime desc
          ) as version_number

    from {{ ref('silver_snapshot_fact_purchase_order') }} snap

),

product as (

    select
          product_key
        , style_number
        , size
        , d365_color_code
        , upc
        , sku
    from {{ ref('dim_product') }}
    where version_number = 1

),

vendor as (

    select
          vendor_key
        , vendor_id
        , vendor_name
    from {{ ref('dim_vendor') }}
    where version_number = 1
      and source_system = 'D365'

),

warehouse as (

    select
          warehouse_key
        , warehouse_id
        , d365_site_id
    from {{ ref('dim_warehouse') }}
    where is_current_row = true

),

standard_cost as (

    -- Current STANDARD cost only -- see dbt_build_conventions's fan-out
    -- warning on fact_product_cost (multiple cost_type/version rows per
    -- product_key), filtered on both columns to avoid it.
    select
          product_key
        , standard_cost_unit
    from {{ ref('fact_product_cost') }}
    where cost_type = 'STANDARD'
      and is_current = true

),

joined as (

    select

          v.*
        , pr.product_key
        , pr.upc
        , pr.sku
        , ve.vendor_key
        , ve.vendor_name
        , wh.warehouse_key
        , sc.standard_cost_unit

    from versioned v

    left join product pr
        on v.ITEMID = pr.style_number
        and v.INVENTCOLORID = pr.d365_color_code
        and v.INVENTSIZEID = pr.size

    left join vendor ve
        on coalesce(v.VENDACCOUNT, v.header_vendaccount) = ve.vendor_id

    left join warehouse wh
        on v.dim_inventlocationid = wh.warehouse_id
        and v.dim_inventsiteid = wh.d365_site_id

    left join standard_cost sc
        on pr.product_key = sc.product_key

),

final as (

    select

    -- Core identifiers
          xxhash64(j.PURCHID, cast(j.LINENUMBER as string), 'D365', cast(j.effective_start_datetime as string)) as purchase_order_key
        , j.PURCHID                                                 as purchase_order_id
        , cast(j.LINENUMBER as int)                                 as purchase_order_line_number
        , cast(null as string) as purchase_order_line_id  -- Source once available: no distinct line-level identifier beyond PURCHID+LINENUMBER found on Rev_PurchLineStaging
        , cast(null as string) as purchase_order_header_id  -- Source once available: PURCHID is both the header and line identifier in this export, no separate header id
        , 'D365'                                                     as source_system

    -- History and row control
        , j.effective_start_datetime                                 as version_start_datetime
        , j.effective_end_datetime                                   as version_end_datetime
        , case when j.version_number = 1 then true else false end    as is_current_row
        , cast(null as string) as change_reason_code  -- Planned per spec -- no change-classification rule defined yet
        , cast(null as string) as change_reason_desc  -- Planned per spec

    -- Dates
        , cast(j.CREATEDDATE as date)                                 as po_created_date
        , cast(null as timestamp) as po_created_datetime  -- Source exists (PurchTable.CREATEDDATE) but tagged Planned in the spec -- phase boundary, not a data gap
        , cast(null as date) as po_approved_date  -- Planned -- no confirmed approved-date field (DOCUMENTSTATUS/WORKFLOWSTATE carry a workflow state, not a timestamp)
        , cast(date_format(j.CREATEDDATE, 'yyyyMMdd') as int)         as order_date_key
        , cast(null as date) as expected_ship_date  -- Source exists (PurchLine.REQUESTEDSHIPDATE/CONFIRMEDSHIPDATE) but tagged Planned in the spec -- NEEDS CONFIRMATION whether to promote this now that the columns are known to exist
        , cast(j.CONFIRMEDDLV as date)                                as expected_receipt_date
        , cast(null as date) as confirmed_receipt_date  -- Planned -- CONFIRMEDDLV is already used above for expected_receipt_date; no separate vendor-reconfirmed date field found -- flag to Nick which of the two spec fields CONFIRMEDDLV is really meant to answer
        , cast(null as date) as first_receipt_date  -- Blocked on the unresolved PO receipt-qty/receipt-event source -- see quantities section
        , cast(null as date) as last_receipt_date  -- Blocked, same reason
        , cast(null as date) as po_closed_date  -- Planned

    -- Vendor and sourcing
        , j.vendor_key
        , coalesce(j.VENDACCOUNT, j.header_vendaccount)               as vendor_id
        , j.vendor_name
        , cast(null as string) as vendor_item_id  -- Planned
        , cast(null as string) as manufacturer_id  -- Planned
        , cast(null as bigint) as buyer_employee_key  -- Source once available: no worker/buyer/sales-rep table found in the warehouse -- same known gap as fact_order_line/fact_sales_invoice's employee_sales_hierarchy_key
        , cast(null as string) as buyer_name  -- Planned, same gap
        , cast(null as string) as incoterm_code  -- Source exists (PurchTable.DLVTERM) but tagged Planned in the spec
        , cast(null as string) as payment_terms  -- Source exists (PurchTable.PAYMENT) but tagged Planned in the spec
        , cast(null as bigint) as country_of_origin_key  -- Planned -- no DIM_COUNTRY model in this project

    -- Product and inventory
        , j.product_key
        , j.ITEMID                                                    as product_id
        , j.upc
        , j.sku
        , j.warehouse_key
        , j.dim_inventlocationid                                      as warehouse_id
        , cast(null as string) as inventory_site_id  -- Source exists (InventDim.inventsiteid, already used for the warehouse join above) but tagged Planned in the spec as its own convenience column
        , cast(null as string) as inventory_status_code  -- Planned

    -- Quantities -- LEFT OPEN per Nick's 2026-09-14 request: no confirmed
    -- PO-receipt-document source exists (no VendPackingSlip* table found),
    -- and PurchLine carries several candidate received-quantity fields
    -- (PURCHRECEIVEDNOW, INVENTRECEIVEDNOW, REMAINPURCHPHYSICAL-derived)
    -- that haven't been reconciled against each other or against
    -- ordered_qty's own unit of measure (PURCHQTY is in purchase unit,
    -- QTYORDERED is in inventory unit -- not guaranteed equal). Every field
    -- below stays null-with-note rather than guessing which source is
    -- authoritative; the raw candidates are captured in
    -- silver_stage_fact_purchase_order's change hash so version history
    -- isn't lost once this gets resolved. Flag to Nick: which of PURCHQTY
    -- vs QTYORDERED is ordered_qty, and which of PURCHRECEIVEDNOW /
    -- INVENTRECEIVEDNOW / (PURCHQTY - REMAINPURCHPHYSICAL) is received_qty.
        , cast(null as decimal(18,4)) as ordered_qty
        , cast(null as decimal(18,4)) as received_qty
        , cast(null as decimal(18,4)) as open_qty
        , cast(null as decimal(18,4)) as cancelled_qty
        , cast(null as decimal(18,4)) as backorder_qty
        , cast(null as string) as qty_uom  -- Blocked on the same ordered/received unit-of-measure question above (PURCHUNIT exists but which qty column it corresponds to is unconfirmed)

    -- Costs and landed cost
        , cast(j.PURCHPRICE as decimal(19,4))                         as unit_cost
        , cast(null as decimal(19,4)) as extended_cost  -- Blocked on ordered_qty (see quantities section)
        , cast(null as decimal(19,4)) as freight_inbound_unit_cost  -- Source once available: same Open Decision #3 gap as FACT_PRODUCT_COST -- no $/unit freight source
        , cast(null as decimal(19,4)) as duty_unit_cost  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as tariff_unit_cost  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as brokerage_unit_cost  -- Source once available: same Open Decision #3 gap as FACT_PRODUCT_COST
        , cast(null as decimal(19,4)) as other_landed_unit_cost  -- Planned
        , cast(null as decimal(19,4)) as landed_cost_unit  -- Reserved per spec Section 6 -- components above are unsourced, so this stays null rather than silently equal unit_cost
        , cast(null as decimal(19,4)) as landed_cost_extended  -- Blocked on landed_cost_unit and ordered_qty
        , j.standard_cost_unit
        , coalesce(j.CURRENCYCODE, j.header_currencycode)             as cost_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as unit_cost_usd  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as landed_cost_unit_usd  -- Phase 2 per spec

    -- Status and workflow
    -- D365 PurchStatus enum on the line: None=0, Backorder=1, Received=2,
    -- Invoiced=3, Canceled=4 (parallel structure to SalesStatus, confirmed
    -- for fact_order_line 2026-09-11; not independently re-verified against
    -- Microsoft's docs this session -- cross-check if this matters for
    -- reporting). This is D365's own native label, not a re-mapping to the
    -- spec's assumed Open/Approved/Received/Closed/Cancelled vocabulary.
        , case j.PURCHSTATUS
            when 0 then 'None'
            when 1 then 'Backorder'
            when 2 then 'Received'
            when 3 then 'Invoiced'
            when 4 then 'Canceled'
            else cast(j.PURCHSTATUS as string)
          end                                                         as po_status
        , cast(null as string) as po_line_status  -- Planned -- PURCHSTATUS above is the only line-level status found
        , cast(null as string) as approval_status  -- Source exists (PurchTable.DOCUMENTSTATUS/WORKFLOWSTATE) but enum mapping unconfirmed -- flag to Nick before wiring up
        , cast(null as string) as receipt_status  -- Blocked on received_qty/open_qty (see quantities section)
        , cast(null as boolean) as is_late_flag  -- Blocked on open_qty (see quantities section)
        , cast(null as boolean) as is_closed_flag  -- D365's PurchStatus enum has no single value that cleanly means "closed" beyond Canceled -- NEEDS CONFIRMATION with Nick what "closed" should mean here (e.g. is Invoiced closed?)
        , j.PURCHSTATUS = 4                                            as is_cancelled_flag
        , cast(null as boolean) as is_drop_ship_flag  -- Source exists (PurchLine/PurchTable.MCRDROPSHIPMENT) but tagged Planned in the spec

    -- Logistics -- all Planned, no source wired
        , cast(null as string) as shipment_mode
        , cast(null as string) as container_id
        , cast(null as string) as bill_of_lading_number
        , cast(null as string) as tracking_number
        , cast(null as string) as port_of_loading  -- Source exists (PORT on both PurchTable and PurchLine) but tagged Planned in the spec, and it's unclear the field specifically means "port of loading"
        , cast(null as string) as port_of_arrival  -- Planned

    -- Derived operational metrics
        , cast(null as int) as days_early_late_to_receipt  -- Blocked on last_receipt_date
        , cast(null as int) as vendor_lead_time_days  -- Blocked on an actual receipt date; spec defines this off receipt date, not expected_receipt_date
        , cast(null as decimal(9,4)) as fill_rate_pct  -- Blocked on received_qty/ordered_qty

    -- Audit and lineage
        , 'silver_stage_fact_purchase_order (PurchTable + PurchLine)'  as record_source_table
        , j.effective_start_datetime                                  as etl_insert_datetime
        , j.etl_update_datetime
        , j.row_hash

    from joined j

)

select * from final
