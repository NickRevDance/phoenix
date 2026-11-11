{{ config(
    materialized = 'incremental',
    unique_key = 'shipment_key',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    merge_exclude_columns = ['etl_insert_datetime'],
    post_hook = [
        "delete from {{ this }} where shipment_status = 'Created' and d365_load_line_rec_id not in (select ll.RECID from {{ ref('silver_d365_whs_load_line') }} ll where ll.INVALID = 0)"
    ]
) }}

-- Accumulating snapshot: every run recomputes all lines and merges only new rows or rows whose row_hash moved.
-- The post-hook drops open-shipment lines D365 has deleted or re-planned (shipped lines are never deleted).

with shipment as (

    select

          s.SHIPMENTID
        , s.REC
        , s.SHIPMENTSTATUS
        , s.LOADID
        , s.ORDERNUM
        , s.INVENTLOCATIONID
        , upper(trim(s.CARRIERCODE)) as wms_carrier_code
        , upper(trim(s.CARRIERSERVICECODE)) as wms_service_code
        , nullif(trim(s.COUNTRYREGIONISOCODE), '') as country_iso_code
        , s.LOCATION_LOCATIONID
        , s.LOGISTICSPOSTALADDRESS_VALIDFROM
        , case when s.SHIPMENTSTATUS = 5 and s.SHIPCONFIRMUTCDATETIME > timestamp('1901-01-01')
               then cast(from_utc_timestamp(s.SHIPCONFIRMUTCDATETIME, 'America/Chicago') as date) end as ship_date  -- ship confirm on the Central clock; matches the packing slip date on 98% of lines

    from {{ ref('silver_d365_whs_shipment_table') }} s

),

ship_to as (

    select

          a.LOCATION_LOCATIONID
        , a.VALIDFROM
        , nullif(trim(a.CITY), '') as ship_to_city
        , nullif(trim(a.STATE), '') as ship_to_state_province
        , nullif(trim(a.ZIPCODE), '') as ship_to_postal_code
        , nullif(trim(a.COUNTRYREGIONID), '') as country_region_id

    from {{ ref('silver_d365_logistics_postal_address') }} a
    qualify row_number() over (partition by a.LOCATION_LOCATIONID, a.VALIDFROM order by a.REC desc) = 1

),

load_line as (

    select

          ll.RECID
        , ll.SHIPMENTID
        , ll.ORDERNUM
        , ll.INVENTTRANSID
        , ll.PICKEDQTY
        , ll.UOM
        , ll.ITEMNETWEIGHT
        , row_number() over (partition by ll.SHIPMENTID order by ll.RECID) as shipment_line_number

    from {{ ref('silver_d365_whs_load_line') }} ll
    where ll.INVALID = 0
      and ll.INVENTTRANSTYPE = 0

),

container_package as (

    select

          cl.SHIPMENTID
        , count(distinct cl.CONTAINERID) as package_count

    from {{ ref('silver_d365_whs_container_line') }} cl
    group by cl.SHIPMENTID

),

container_header as (

    select

          ct.SHIPMENTID
        , sum(case when upper(ct.WEIGHTUOM) = 'KG' then ct.WEIGHT * 2.20462 else ct.WEIGHT end) as total_weight_lbs
        , min_by(nullif(trim(ct.MASTERTRACKINGNUM), ''), named_struct('no_tracking', nullif(trim(ct.MASTERTRACKINGNUM), '') is null, 'rec', ct.REC)) as tracking_number  -- first container with a tracking number; SHIPCARRIERTRACKINGNUM is mostly free-text notes

    from {{ ref('silver_d365_whs_container_table') }} ct
    group by ct.SHIPMENTID

),

sales_line as (

    select

          sl.INVENTTRANSID
        , sl.REC
        , nullif(trim(sl.DLVMODE), '') as dlv_mode

    from {{ ref('silver_d365_sales_line') }} sl

),

order_line as (

    select

          ol.d365_sales_line_rec_id
        , ol.order_line_number
        , ol.product_key
        , ol.customer_key
        , ol.sales_channel_key

    from {{ ref('fact_order_line') }} ol

),

warehouse as (

    select

          w.warehouse_key
        , w.warehouse_id

    from {{ ref('dim_warehouse') }} w
    where w.version_number = 1

),

line_base as (

    select

          ll.RECID as d365_load_line_rec_id
        , ll.SHIPMENTID as shipment_id
        , cast(ll.shipment_line_number as int) as shipment_line_number
        , s.REC as d365_shipment_rec_id
        , s.LOADID as load_id
        , s.SHIPMENTSTATUS as d365_shipment_status_code
        , coalesce(nullif(ll.ORDERNUM, ''), s.ORDERNUM) as order_id
        , ll.INVENTTRANSID as inventtransid
        , sl.REC as d365_sales_line_rec_id
        , ol.order_line_number
        , coalesce(ol.product_key, '-1') as product_key
        , coalesce(ol.customer_key, cast(-1 as bigint)) as customer_key
        , coalesce(ol.sales_channel_key, cast(-1 as bigint)) as sales_channel_key
        , coalesce(wh.warehouse_key, cast(-1 as bigint)) as warehouse_key
        , s.ship_date
        , case when s.SHIPMENTSTATUS = 5 then 'Picked Up' else 'Created' end as shipment_status  -- spec 7.1: ship confirm is the carrier handoff; later statuses need the carrier feed
        , case when s.SHIPMENTSTATUS = 5 then cast(ll.PICKEDQTY as decimal(18,4)) else cast(0 as decimal(18,4)) end as shipped_qty
        , nullif(trim(ll.UOM), '') as qty_uom
        , case
            when s.wms_carrier_code in ('UPS', 'FEDEX', 'USPS', 'FRONTIER') then s.wms_carrier_code
            when s.wms_carrier_code <> '' then 'UNKNOWN'
            when sl.dlv_mode is null then 'UNKNOWN'
            else case upper(split(sl.dlv_mode, '-')[0])
                when 'UPS'        then 'UPS'
                when 'FEDEX'      then 'FEDEX'
                when 'USPS'       then 'USPS'
                when 'FRONT'      then 'FRONTIER'
                when 'IDS'        then 'IDS'
                when 'SHIPTODESK' then 'SHIP_TO_DESK'
                else 'UNKNOWN'
            end
          end as carrier_code  -- WMS carrier; IDS and Ship to Desk carry none on the shipment, so the order line's delivery mode (FACT_ORDERS_RETURNS 7.11 token rule) fills it
        , case when s.wms_carrier_code <> '' then coalesce(s.wms_service_code, '') else '' end as service_code
        , case when s.SHIPMENTSTATUS = 5 and ll.ITEMNETWEIGHT > 0
               then cast(ll.ITEMNETWEIGHT * ll.PICKEDQTY as decimal(10,2)) end as line_weight_lbs  -- item master net weight x qty; runs above the packed carton weight (median 1.38x), so it drives allocation shares only
        , coalesce(s.country_iso_code, st.country_region_id) as ship_to_country_code
        , st.ship_to_city
        , st.ship_to_state_province
        , st.ship_to_postal_code
        , cast(cp.package_count as int) as package_count
        , cast(ch.total_weight_lbs as decimal(10,2)) as total_weight_lbs
        , ch.tracking_number

    from load_line ll
    inner join shipment s
        on s.SHIPMENTID = ll.SHIPMENTID
    left join ship_to st
        on st.LOCATION_LOCATIONID = s.LOCATION_LOCATIONID
       and st.VALIDFROM = s.LOGISTICSPOSTALADDRESS_VALIDFROM
    left join sales_line sl
        on sl.INVENTTRANSID = ll.INVENTTRANSID
    left join order_line ol
        on ol.d365_sales_line_rec_id = sl.REC
    left join warehouse wh
        on wh.warehouse_id = s.INVENTLOCATIONID
    left join container_package cp
        on cp.SHIPMENTID = ll.SHIPMENTID
    left join container_header ch
        on ch.SHIPMENTID = ll.SHIPMENTID

),

packing_slip_match as (

    select

          b.d365_load_line_rec_id
        , pst.PACKINGSLIPID as packing_slip_id

    from line_base b
    inner join {{ ref('silver_d365_cust_packing_slip_trans') }} pst
        on pst.INVENTTRANSID = b.inventtransid
       and pst.QTY > 0
    inner join {{ ref('silver_d365_cust_packing_slip_jour') }} psj
        on psj.SALESID = pst.SALESID
       and psj.PACKINGSLIPID = pst.PACKINGSLIPID
    where b.shipment_status = 'Picked Up'
    qualify row_number() over (
        partition by b.d365_load_line_rec_id
        order by case when pst.QTY = b.shipped_qty then 0 else 1 end
               , abs(datediff(psj.DELIVERYDATE, b.ship_date))
               , pst.PACKINGSLIPID
    ) = 1  -- 99% of lines have one shipment and one slip; splits pair on qty, then nearest date

),

invoice_match as (

    select

          b.d365_load_line_rec_id
        , cit.INVOICEID as invoice_id

    from line_base b
    inner join {{ ref('silver_d365_cust_invoice_trans') }} cit
        on cit.INVENTTRANSID = b.inventtransid
       and cit.QTY > 0
    where b.shipment_status = 'Picked Up'
    qualify row_number() over (
        partition by b.d365_load_line_rec_id
        order by case when cit.QTY = b.shipped_qty then 0 else 1 end
               , abs(datediff(cit.INVOICEDATE, b.ship_date))
               , cit.INVOICEID
    ) = 1

),

enriched as (

    select

          b.*
        , ps.packing_slip_id
        , im.invoice_id
        , svc.carrier_name
        , case when b.service_code <> '' then concat(b.carrier_code, '_', b.service_code) end as carrier_service_code
        , coalesce(svc.shipping_method, 'Other') as shipping_method
        , svc.sla_transit_days
        , svc.sla_business_days_flag
        , size(collect_set(b.shipment_id) over (partition by b.order_id)) > 1 as is_split_shipment_flag  -- spec 7.4
        , cast(null as decimal(19,4)) as shipping_cost_total  -- Source once available: carrier billing -- no outbound carrier cost in the D365 export (spec Open Decision 2, EDW-60)
        , sum(b.line_weight_lbs) over (partition by b.shipment_id) as shipment_line_weight_lbs
        , sum(b.shipped_qty) over (partition by b.shipment_id) as shipment_shipped_qty
        , count(case when b.shipped_qty > 0 and b.line_weight_lbs is null then 1 end) over (partition by b.shipment_id) as shipment_lines_missing_weight

    from line_base b
    left join packing_slip_match ps
        on ps.d365_load_line_rec_id = b.d365_load_line_rec_id
    left join invoice_match im
        on im.d365_load_line_rec_id = b.d365_load_line_rec_id
    left join {{ ref('ref_shipping_service') }} svc
        on svc.carrier_code = b.carrier_code
       and svc.service_code = b.service_code

),

final as (

    select

    -- Core ID
          {{ generate_surrogate_key(['e.d365_load_line_rec_id', "'D365'"]) }} as shipment_key
        , e.shipment_id
        , e.shipment_line_number
        , 'D365' as source_system
        , e.order_id
        , e.order_line_number
        , e.invoice_id
        , e.packing_slip_id
        , cast(null as string) as bigcommerce_shipment_id  -- Phase 2 per spec

    -- Dim FKs
        , cast(date_format(e.ship_date, 'yyyyMMdd') as int) as ship_date_key
        , cast(date_format(date_add(e.ship_date, e.sla_transit_days), 'yyyyMMdd') as int) as sla_delivery_date_key
        , cast(null as int) as actual_delivery_date_key  -- Phase 2 per spec
        , e.product_key
        , e.customer_key
        , e.sales_channel_key
        , e.warehouse_key
        , cast(null as bigint) as employee_sales_hierarchy_key  -- Phase 2 per spec
        , cast(null as bigint) as packed_by_employee_key  -- Phase 2 per spec

    -- Dates
        , e.ship_date
        , cast(null as timestamp) as ship_datetime  -- Phase 2 per spec
        , date_add(e.ship_date, e.sla_transit_days) as sla_delivery_date  -- NEEDS CONFIRMATION: calendar days until Operations supplies SLA data (Open Decision 5)
        , cast(null as date) as estimated_delivery_date  -- Phase 2 per spec
        , cast(null as date) as actual_delivery_date  -- Phase 2 per spec
        , cast(null as timestamp) as delivery_confirmation_datetime  -- Phase 2 per spec
        , cast(null as timestamp) as carrier_pickup_datetime  -- Phase 2 per spec

    -- Carrier
        , e.carrier_code
        , e.carrier_name
        , e.carrier_service_code
        , e.shipping_method
        , e.tracking_number
        , cast(null as string) as secondary_tracking_number  -- Phase 3 per spec
        , cast(null as string) as shipping_account_number  -- Phase 2 per spec
        , cast(null as string) as carrier_delivery_status  -- Phase 2 per spec

    -- Quantities
        , e.shipped_qty
        , e.qty_uom

    -- Costs
        , e.shipping_cost_total
        , cast(e.shipping_cost_total * case
              when e.shipment_lines_missing_weight = 0 and e.shipment_line_weight_lbs > 0 then e.line_weight_lbs / e.shipment_line_weight_lbs
              else e.shipped_qty / nullif(e.shipment_shipped_qty, 0)
          end as decimal(19,4)) as shipping_cost_allocated  -- spec 7.2: pro-rata by weight; unit share for the whole shipment when any shipped line has no weight
        , cast(null as decimal(19,4)) as fuel_surcharge_amount  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as accessorial_charge_amount  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as insurance_amount  -- Phase 3 per spec
        , cast(null as string) as shipping_cost_currency_code  -- Source once available: carrier billing (Open Decision 2)
        , cast(null as decimal(19,4)) as quoted_shipping_rate  -- Phase 3 per spec

    -- Destination
        , e.ship_to_city
        , e.ship_to_state_province
        , e.ship_to_postal_code
        , e.ship_to_country_code
        , cast(null as string) as shipping_zone  -- Phase 2 per spec

    -- Status
        , e.shipment_status
        , cast(null as boolean) as is_delivered_flag  -- Source once available: carrier tracking feed (Open Decision 6)
        , cast(null as boolean) as is_exception_flag  -- Source once available: carrier tracking feed (Open Decision 6)
        , cast(null as string) as exception_reason  -- Phase 2 per spec
        , cast(null as boolean) as is_signature_required_flag  -- Phase 2 per spec
        , cast(null as boolean) as is_residential_flag  -- Phase 2 per spec
        , e.is_split_shipment_flag

    -- Package
        , e.package_count
        , e.total_weight_lbs
        , e.line_weight_lbs
        , cast(null as decimal(10,2)) as dimensional_weight_lbs  -- Phase 2 per spec
        , cast(null as decimal(10,2)) as billed_weight_lbs  -- Phase 2 per spec

    -- SLA
        , e.sla_transit_days
        , e.sla_business_days_flag

    -- Audit
        , e.d365_shipment_rec_id
        , e.d365_load_line_rec_id
        , e.d365_sales_line_rec_id
        , e.d365_shipment_status_code
        , e.load_id
        , 'silver_d365_whs_load_line + silver_d365_whs_shipment_table' as record_source_table
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime
        , {{ generate_row_hash([
              "coalesce(e.shipment_status, '')"
            , "coalesce(cast(e.shipped_qty as string), '')"
            , "coalesce(cast(e.ship_date as string), '')"
            , "coalesce(e.order_id, '')"
            , "coalesce(e.invoice_id, '')"
            , "coalesce(e.packing_slip_id, '')"
            , "coalesce(e.product_key, '')"
            , "coalesce(cast(e.customer_key as string), '')"
            , "coalesce(cast(e.sales_channel_key as string), '')"
            , "coalesce(cast(e.warehouse_key as string), '')"
            , "coalesce(e.carrier_code, '')"
            , "coalesce(e.carrier_service_code, '')"
            , "coalesce(e.shipping_method, '')"
            , "coalesce(e.tracking_number, '')"
            , "coalesce(cast(e.package_count as string), '')"
            , "coalesce(cast(e.total_weight_lbs as string), '')"
            , "coalesce(cast(e.line_weight_lbs as string), '')"
            , "coalesce(e.ship_to_city, '')"
            , "coalesce(e.ship_to_state_province, '')"
            , "coalesce(e.ship_to_postal_code, '')"
            , "coalesce(e.ship_to_country_code, '')"
            , "coalesce(cast(e.is_split_shipment_flag as string), '')"
            , "coalesce(cast(e.sla_transit_days as string), '')"
            , "coalesce(cast(e.shipment_line_number as string), '')"
          ]) }} as row_hash

    from enriched e

)

select f.*
from final f
{% if is_incremental() %}
left join {{ this }} ex
    on ex.shipment_key = f.shipment_key
where ex.shipment_key is null
   or ex.row_hash <> f.row_hash
{% endif %}
