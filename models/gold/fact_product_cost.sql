{{ config(materialized = 'table') }}

with deduped as (

    select

          snap.*
        , row_number() over (
            partition by snap.product_id, snap.cost_type, snap.source_system, snap.effective_date
            order by snap.effective_start_datetime desc
          ) as grain_dedup_rn

    from {{ ref('silver_snapshot_fact_product_cost') }} snap

),

versioned as (

    select

          d.*
        -- 2026-09-16 fix: partition by product_id+cost_type, not product_cost_entity_key --
        -- the latter folds in source_system, which is derived on the LANDED branch and forked a product's cost history into two "current" rows once its PLM estimate populated (product_id 10003). Matches spec: is_current is per product + cost_type.
        , row_number() over (
            partition by d.product_id, d.cost_type
            order by d.effective_start_datetime desc
          ) as version_number

        , case d.cost_type
            when 'STANDARD' then d.standard_cost_unit
            when 'LANDED' then d.landed_cost_unit
            when 'VENDOR' then d.vendor_cost_unit
            when 'PLM_ESTIMATED' then d.plm_estimated_cost_unit
          end as cost_value

    from deduped d
    where d.grain_dedup_rn = 1

),

vendor_keyed as (

    select

          v.*
        , case
            when v.vendor_id is null then cast({{ default_member_key() }} as bigint)
            when dv.vendor_key is not null then dv.vendor_key
            else cast({{ unknown_member_key() }} as bigint)
          end as vendor_key

    from versioned v
    left join {{ ref('dim_vendor') }} dv
        on dv.vendor_id = v.vendor_id
        and dv.source_system = 'D365'
        and dv.is_current_row = 1

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
        , case
            when v.effective_date is null then cast({{ unknown_member_key() }} as int)
            else cast(date_format(v.effective_date, 'yyyyMMdd') as int)
          end as effective_date_key  -- EDW-94 A4: 1900-01-01 D365 placeholder nulls out effective_date upstream; route to DIM_DATE's unknown member instead of a literal 19000101 key
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
        , v.vendor_key

        , v.plm_estimated_cost_unit
        , v.plm_estimated_freight_unit
        , v.plm_estimated_duty_pct
        , v.plm_estimated_tariff_pct

        , v.cost_currency_code
        , v.fx_rate_to_usd
        , v.standard_cost_unit_usd
        , v.landed_cost_unit_usd
        , v.vendor_cost_unit_usd
        , v.plm_estimated_cost_unit_usd

        , case when v.version_number = 1 then cast(1 as boolean) else cast(0 as boolean) end as is_current
        , case when v.version_number = 1 then 'Active' else 'Superseded' end as cost_status

        , lag(v.cost_value) over (
            partition by v.product_id, v.cost_type
            order by v.effective_start_datetime
          ) as prior_cost_unit
        , v.cost_value - lag(v.cost_value) over (
            partition by v.product_id, v.cost_type
            order by v.effective_start_datetime
          ) as cost_change_amount
        , case
            when lag(v.cost_value) over (
                   partition by v.product_id, v.cost_type
                   order by v.effective_start_datetime
                 ) is null
              or lag(v.cost_value) over (
                   partition by v.product_id, v.cost_type
                   order by v.effective_start_datetime
                 ) = 0
            then null
            else (v.cost_value - lag(v.cost_value) over (
                    partition by v.product_id, v.cost_type
                    order by v.effective_start_datetime
                  )) / lag(v.cost_value) over (
                    partition by v.product_id, v.cost_type
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

    from vendor_keyed v

)

select * from final
