{{ config(materialized = 'table') }}

-- FACT_PURCHASE_ORDER v1.0: one row per PO line version, from silver_snapshot_fact_purchase_order.
-- Items bought outside the merchandise range (catalog packs, accessory purchases) resolve to product_key '0', Not Applicable.
{% set non_merchandise_item_patterns = ['ACCESS%', 'CAT-BUNDLE-%', '%CATPKG'] %}

with versioned as (

    select

          snap.*
        , {{ scd2_version_number('snap.purchase_order_entity_key') }} as version_number

    from {{ ref('silver_snapshot_fact_purchase_order') }} snap

),

product_by_upc as (

    select
          p.product_key
        , p.upc
        , p.sku
    from {{ ref('dim_product') }} p
    where p.version_number = 1

),

product_by_variant as (

    -- Fallback where PurchLine.BARCODE is blank; item numbers are case-inconsistent in the source.
    select
          lower(p.style_number) as style_number_lower
        , p.d365_color_code
        , p.size
        , p.product_key
        , p.upc
        , p.sku
    from {{ ref('dim_product') }} p
    where p.version_number = 1
      and p.product_key not in ('-1', '0')
    qualify row_number() over (partition by lower(p.style_number), p.d365_color_code, p.size order by p.upc) = 1

),

vendor as (

    select
          v.vendor_key
        , v.vendor_id
        , v.vendor_name
    from {{ ref('dim_vendor') }} v
    where v.version_number = 1
      and v.source_system = 'D365'

),

warehouse as (

    select
          w.warehouse_key
        , w.warehouse_id
        , w.d365_site_id
    from {{ ref('dim_warehouse') }} w
    where w.version_number = 1  -- EDW-90 item 4: facts resolve on the latest version

),

standard_cost as (

    select
          c.product_id
        , c.standard_cost_unit
    from {{ ref('fact_product_cost') }} c
    where c.cost_type = 'STANDARD'
      and c.is_current = true

),

resolved as (

    select

          v.*
        , case
            when coalesce(pu.product_key, pv.product_key) is not null then coalesce(pu.product_key, pv.product_key)
            when v.STOCKEDPRODUCT = 0
              {%- for pattern in non_merchandise_item_patterns %}
              or upper(v.ITEMID) like '{{ pattern }}'
              {%- endfor %}
                then '{{ default_member_key() }}'
            else '{{ unknown_member_key() }}'
          end                                                                   as product_key
        , coalesce(pu.upc, pv.upc)                                              as upc
        , coalesce(pu.sku, pv.sku)                                              as sku
        , coalesce(ve.vendor_key, {{ unknown_member_key() }})                   as vendor_key
        , coalesce(v.VENDACCOUNT, v.ORDERACCOUNT)                               as vendor_id
        , ve.vendor_name
        , coalesce(wh.warehouse_key, {{ unknown_member_key() }})                as warehouse_key
        , sc.standard_cost_unit

    from versioned v

    left join product_by_upc pu
        on nullif(v.BARCODE, '') is not null
        and md5(concat_ws('|', v.BARCODE)) = pu.product_key

    left join product_by_variant pv
        on nullif(v.BARCODE, '') is null
        and lower(v.ITEMID) = pv.style_number_lower
        and v.INVENTCOLORID = pv.d365_color_code
        and v.INVENTSIZEID = pv.size

    left join vendor ve
        on coalesce(v.VENDACCOUNT, v.ORDERACCOUNT) = ve.vendor_id

    left join warehouse wh
        on v.warehouse_id = wh.warehouse_id
        and v.inventory_site_id = wh.d365_site_id

    left join standard_cost sc
        on v.ITEMID = sc.product_id

),

final as (

    select

    -- Core identifiers
          {{ generate_surrogate_key(["r.PURCHID", "cast(r.LINENUMBER as string)", "'D365'", "cast(r.effective_start_datetime as string)"]) }} as purchase_order_key
        , r.purchase_order_entity_key
        , r.PURCHID                                                             as purchase_order_id
        , cast(r.LINENUMBER as int)                                             as purchase_order_line_number
        , r.INVENTTRANSID                                                       as d365_invent_trans_id
        , r.INVENTDIMID                                                         as d365_invent_dim_id
        , 'D365'                                                                as source_system
        , cast(null as string)                                                  as purchase_order_line_id    -- not maintained: PURCHID is both header and line id in this export
        , cast(null as string)                                                  as purchase_order_header_id  -- not maintained: same

    -- History
        , r.effective_start_datetime
        , r.effective_end_datetime
        , {{ scd2_is_current_row() }}                                           as is_current_row
        , r.version_number
        , cast(null as string)                                                  as change_reason_code  -- Phase 2
        , cast(null as string)                                                  as change_reason_desc  -- Phase 2

    -- Classification
        , r.purchase_order_class
        , r.po_series_code
        , r.VENDGROUP                                                           as vendor_group_code
        , r.REVREASON                                                           as po_revision_label

    -- Dates
        , cast(r.CREATEDDATE as date)                                           as po_created_date
        , cast(r.CREATEDDATE as timestamp)                                      as po_created_datetime
        , coalesce(cast(date_format(r.CREATEDDATE, 'yyyyMMdd') as int), {{ unknown_member_key() }})  as order_date_key
        , r.ACCOUNTINGDATE                                                      as accounting_date
        , r.DELIVERYDATE                                                        as expected_receipt_date
        , coalesce(cast(date_format(r.DELIVERYDATE, 'yyyyMMdd') as int), {{ unknown_member_key() }}) as expected_receipt_date_key
        , r.CONFIRMEDDLV                                                        as confirmed_receipt_date
        , r.ITMEXFACTORYDATE                                                    as ex_factory_date
        , r.ITMINTOSTOREDATE                                                    as into_store_date
        , r.shipped_date
        , r.expected_arrival_date
        , r.first_receipt_date
        , r.last_receipt_date
        , cast(null as date)                                                    as po_approved_date  -- not maintained: no approval timestamp
        , cast(null as date)                                                    as po_closed_date    -- not maintained: no closure timestamp

    -- Vendor
        , r.vendor_key
        , r.vendor_id
        , r.vendor_name
        , r.PAYMENT                                                             as payment_terms_code
        , cast(null as string)                                                  as incoterm_code          -- not maintained: DLVTERM is Default or blank
        , cast(null as string)                                                  as vendor_item_id         -- not maintained: EXTERNALITEMID blank
        , cast(null as string)                                                  as manufacturer_id        -- not maintained
        , cast(null as bigint)                                                  as buyer_employee_key     -- Phase 2: no buyer on the PO (DIM_EMPLOYEE, EDW-18)
        , cast(null as string)                                                  as buyer_name             -- Phase 2
        , cast(null as bigint)                                                  as country_of_origin_key  -- Phase 3: ORIGCOUNTRYREGIONID blank, no DIM_COUNTRY

    -- Product and warehouse
        , r.product_key
        , r.ITEMID                                                              as product_id
        , r.upc
        , r.sku
        , r.NAME                                                                as product_line_description
        , r.warehouse_key
        , r.warehouse_id
        , r.inventory_site_id
        , cast(null as string)                                                  as inventory_status_code  -- not maintained: assigned at receipt

    -- Quantities
        , cast(r.PURCHQTY as decimal(18,4))                                     as ordered_qty
        , cast(r.REMAINPURCHPHYSICAL as decimal(18,4))                          as remaining_physical_qty
        , r.in_transit_qty
        , r.received_qty
        , r.invoiced_qty
        , r.cancelled_qty
        , cast(r.PURCHQTY - r.received_qty - r.cancelled_qty as decimal(18,4))  as open_qty
        , r.PURCHUNIT                                                           as qty_uom

    -- Costs
        , cast(r.PURCHPRICE as decimal(19,4))                                   as unit_cost
        , cast(r.PURCHQTY * r.PURCHPRICE as decimal(19,4))                      as extended_cost
        , cast((r.PURCHQTY - r.received_qty - r.cancelled_qty) * r.PURCHPRICE as decimal(19,4)) as open_extended_cost
        , cast(r.standard_cost_unit as decimal(19,4))                           as standard_cost_unit
        , case when r.PURCHPRICE <> 0 and r.standard_cost_unit is not null
               then cast(r.PURCHPRICE - r.standard_cost_unit as decimal(19,4)) end as cost_variance_unit
        , r.CURRENCYCODE                                                        as cost_currency_code
        , cast(null as decimal(19,8))                                           as fx_rate_to_usd          -- Phase 2: REF_FX_RATE (EDW-127)
        , cast(null as decimal(19,4))                                           as unit_cost_usd           -- Phase 2
        , cast(null as decimal(19,4))                                           as landed_cost_unit_usd    -- Phase 2
        , cast(null as decimal(19,4))                                           as freight_inbound_unit_cost  -- Phase 2: allocation is EDW-60 / EDW-94
        , cast(null as decimal(19,4))                                           as duty_unit_cost          -- Phase 2
        , cast(null as decimal(19,4))                                           as tariff_unit_cost        -- Phase 2
        , cast(null as decimal(19,4))                                           as brokerage_unit_cost     -- Phase 2
        , cast(null as decimal(19,4))                                           as other_landed_unit_cost  -- Phase 2
        , cast(null as decimal(19,4))                                           as landed_cost_unit        -- Phase 2: never silently equal to unit_cost
        , cast(null as decimal(19,4))                                           as landed_cost_extended    -- Phase 2

    -- Status
        , case r.PURCHSTATUS
            when 0 then 'None' when 1 then 'Backorder' when 2 then 'Received' when 3 then 'Invoiced' when 4 then 'Canceled'
            else cast(r.PURCHSTATUS as string)
          end                                                                   as po_line_status
        , case r.header_purchstatus
            when 0 then 'None' when 1 then 'Backorder' when 2 then 'Received' when 3 then 'Invoiced' when 4 then 'Canceled'
            else cast(r.header_purchstatus as string)
          end                                                                   as po_status
        , case r.DOCUMENTSTATUS
            when 0 then 'None' when 2 then 'Purchase Order' when 5 then 'Product Receipt' when 7 then 'Invoice'
            else cast(r.DOCUMENTSTATUS as string)
          end                                                                   as document_status
        , case r.DOCUMENTSTATE
            when 30 then 'Approved' when 40 then 'Confirmed'
            else cast(r.DOCUMENTSTATE as string)
          end                                                                   as approval_state  -- NEEDS CONFIRMATION: labels assumed from VersioningDocumentState (Open Decision 4)
        , r.REVMANUFACTURINGSTATUS                                              as manufacturing_status
        , r.ITMSTATUSID                                                         as transit_status
        , case
            when r.PURCHSTATUS = 4 then 'Cancelled'
            when r.received_qty <= 0 then 'Not Received'
            when r.received_qty < r.PURCHQTY then 'Partially Received'
            else 'Fully Received'
          end                                                                   as receipt_status
        , case when r.PURCHSTATUS in (3, 4) and r.in_transit_qty = 0 then 1 else 0 end as is_closed_flag
        , case when r.PURCHSTATUS = 4 then 1 else 0 end                         as is_cancelled_flag
        , cast(r.MCRDROPSHIPMENT as int)                                        as is_drop_ship_flag
        , case when abs(r.PURCHQTY) > 1000000 then 1 else 0 end                 as is_quantity_outlier_flag

    -- Logistics
        , coalesce(r.DLVMODE, r.header_dlvmode)                                 as shipment_mode_code
        , r.goods_in_transit_id
        , cast(null as string)                                                  as container_id           -- Phase 3: no source
        , cast(null as string)                                                  as bill_of_lading_number  -- Phase 3
        , cast(null as string)                                                  as tracking_number        -- Phase 3
        , cast(null as string)                                                  as port_of_loading        -- Phase 3: PORT blank
        , cast(null as string)                                                  as port_of_arrival        -- Phase 3

    -- Derived
        , datediff(r.first_receipt_date, cast(r.CREATEDDATE as date))           as vendor_lead_time_days
        , datediff(r.last_receipt_date, coalesce(r.CONFIRMEDDLV, r.DELIVERYDATE)) as days_early_late_to_receipt
        , case when r.PURCHQTY > 0 then cast(r.received_qty / r.PURCHQTY as decimal(9,4)) end as fill_rate_pct

    -- Audit
        , 'silver_stage_fact_purchase_order'                                    as record_source_table
        , r.effective_start_datetime                                            as etl_insert_datetime
        , r.etl_update_datetime
        , r.row_hash

    from resolved r

)

select * from final
