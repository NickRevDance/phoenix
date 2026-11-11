{{ config(severity = 'warn') }}

-- EDW-69: every carrier + service on FACT_SHIPMENT has a row in ref_shipping_service (unmapped lands as 'Other').

select
      f.carrier_code
    , f.carrier_service_code
    , count(*) as shipment_lines
from {{ ref('fact_shipment') }} f
left join {{ ref('ref_shipping_service') }} r
    on r.carrier_code = f.carrier_code
   and coalesce(r.carrier_service_code, '') = coalesce(f.carrier_service_code, '')
where r.carrier_code is null
group by f.carrier_code, f.carrier_service_code
