{{ config(materialized = 'table') }}

with seed_typed as (

    select

          upper(trim(s.carrier_code)) as carrier_code
        , coalesce(upper(trim(s.service_code)), '') as service_code  -- the blank-service rows load as null
        , trim(s.carrier_name) as carrier_name
        , trim(s.carrier_service_name) as carrier_service_name
        , trim(s.shipping_method) as shipping_method
        , cast(nullif(trim(s.sla_transit_days), '') as int) as sla_transit_days
        , cast(s.sla_business_days_flag as int) = 1 as sla_business_days_flag
        , cast(s.is_carrier_metric_eligible as int) = 1 as is_carrier_metric_eligible
        , nullif(trim(s.classification_owner), '') as classification_owner
        , cast(s.classified_date as date) as classified_date
        , nullif(trim(s.notes), '') as notes

    from {{ ref('shipping_service_map') }} s

),

final as (

    select

          t.carrier_code
        , t.service_code
        , case when t.service_code = '' then null else concat(t.carrier_code, '_', t.service_code) end as carrier_service_code
        , t.carrier_name
        , t.carrier_service_name
        , t.shipping_method
        , t.sla_transit_days
        , t.sla_business_days_flag
        , t.is_carrier_metric_eligible
        , t.classification_owner
        , t.classified_date
        , t.notes
        , 'shipping_service_map' as record_source
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

    from seed_typed t

)

select * from final
