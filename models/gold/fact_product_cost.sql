{{ config(materialized = 'table') }}

with versioned as (

    select

          snap.*
        , row_number() over (
            partition by snap.product_cost_entity_key
            order by snap.effective_start_datetime desc
          ) as version_number

        , case snap.cost_type
            when 'STANDARD' then snap.standard_cost_unit
            when 'LANDED' then snap.landed_cost_unit
            when 'VENDOR' then snap.vendor_cost_unit
            when 'PLM_ESTIMATED' then snap.plm_estimated_cost_unit
          end as cost_value

    from {{ ref('silver_snapshot_fact_product_cost') }} snap

),

final as (

    select

          xxhash64(v.product_id, v.cost_type, v.source_system, cast(v.effective_date as string)) as product_cost_key

        , v.product_key
        , v.product_id
        , v.sku
        , v.source_system

        , v.cost_type
        , v.cost_subtype
        , v.cost_method

        , v.effective_date
        , cast(date_format(v.effective_date, 'yyyyMMdd') as int) as effective_date_key
        , cast(v.effective_end_datetime as date) as expiration_date
        , v.d365_cost_update_datetime

        , v.standard_cost_unit
        , v.landed_cost_unit
        , v.freight_cost_unit
        , v.duty_cost_unit
        , v.tariff_cost_unit
        , v.brokerage_cost_unit
        , v.other_landed_cost_unit

        , v.vendor_cost_unit
        , v.vendor_id
        , v.vendor_name

        , v.plm_estimated_cost_unit
        , v.plm_estimated_freight_unit
        , v.plm_estimated_duty_pct
        , v.plm_estimated_tariff_pct

        , v.cost_currency_code
        , v.fx_rate_to_usd
        , v.standard_cost_unit_usd
        , v.landed_cost_unit_usd
        , v.vendor_cost_unit_usd

        , case when v.version_number = 1 then cast(1 as boolean) else cast(0 as boolean) end as is_current
        , case when v.version_number = 1 then 'Active' else 'Superseded' end as cost_status

        , lag(v.cost_value) over (
            partition by v.product_cost_entity_key
            order by v.effective_start_datetime
          ) as prior_cost_unit
        , v.cost_value - lag(v.cost_value) over (
            partition by v.product_cost_entity_key
            order by v.effective_start_datetime
          ) as cost_change_amount
        , case
            when lag(v.cost_value) over (
                   partition by v.product_cost_entity_key
                   order by v.effective_start_datetime
                 ) is null
              or lag(v.cost_value) over (
                   partition by v.product_cost_entity_key
                   order by v.effective_start_datetime
                 ) = 0
            then null
            else (v.cost_value - lag(v.cost_value) over (
                    partition by v.product_cost_entity_key
                    order by v.effective_start_datetime
                  )) / lag(v.cost_value) over (
                    partition by v.product_cost_entity_key
                    order by v.effective_start_datetime
                  ) * 100
          end as cost_change_pct
        , v.change_reason_code

        , v.d365_item_cost_id
        , v.d365_cost_group
        , v.d365_cost_version

        , v.record_source_table
        , v.effective_start_datetime as etl_insert_datetime
        , v.etl_update_datetime
        , v.row_hash

    from versioned v

)

select * from final
