with standard_cost as (

    select

          ITEMID       as product_id
        , PRICE        as standard_cost_unit
        , PRICEDATE    as standard_cost_effective_date
        , MODIFIEDDATE as d365_cost_update_datetime

    from {{ ref('silver_d365_inventory_product_cost') }}

),

dim_product_cost as (

    select

          product_key
        , product_id
        , SKU                       as sku
        , currency_code             as cost_currency_code
        , plm_estimated_landed_cost as landed_cost_unit
        , plm_estimated_freight_rate as freight_cost_unit
        , duty_calculated            as duty_cost_unit
        , tariff_calculated          as tariff_cost_unit
        , plm_estimated_freight_rate as plm_estimated_freight_unit
        , duty_percentage            as plm_estimated_duty_pct
        , tariff_percent             as plm_estimated_tariff_pct
        , product_group
        , product_supplier

    from {{ ref('dim_product') }}
    where version_number = 1

),

combined as (

    select

          coalesce(s.product_id, d.product_id) as product_id

        , d.product_key
        , d.sku
        , d.cost_currency_code

        , s.standard_cost_unit
        , s.standard_cost_effective_date
        , s.d365_cost_update_datetime

        , d.landed_cost_unit
        , d.freight_cost_unit
        , d.duty_cost_unit
        , d.tariff_cost_unit

        , d.plm_estimated_freight_unit
        , d.plm_estimated_duty_pct
        , d.plm_estimated_tariff_pct

        , d.product_group
        , d.product_supplier

    from standard_cost s
    full outer join dim_product_cost d
        on s.product_id = d.product_id

),

final as (

    select

        -- Surrogate PK: unique per product row. xxhash64 returns a native
        -- BIGINT in Databricks, matching the spec's product_cost_key data
        -- type without an extra surrogate-key package dependency.
          xxhash64(c.product_id)                as product_cost_key

        , c.product_key
        , c.product_id
        , c.sku

        , c.standard_cost_unit
        , c.standard_cost_effective_date
        , c.d365_cost_update_datetime
        , null d365_cost_version                -- Source once available: D365 InventCostPrice.CostingVersionId -- InventCostPrice not yet ingested via BYOD
        , null d365_item_cost_id                -- Source once available: D365 InventCostPrice record id -- not yet ingested via BYOD
        , null d365_cost_group                  -- Source once available: bronze_inventory_item / Rev_InventTableStaging.COSTGROUPID -- requires a join to the item master not built here yet

        , c.landed_cost_unit
        , c.freight_cost_unit
        , c.duty_cost_unit
        , c.tariff_cost_unit
        , null brokerage_cost_unit              -- Source once available: no brokerage-specific column on the Centric PLM export -- Finance/Ops to confirm per spec Open Decision #3
        , null other_landed_cost_unit           -- Source once available: silver_centric_product_current.CommissionPerItem, once silver_stage_dim_product propagates it into dim_product
        , null landed_cost_effective_date       -- Source once available: silver_centric_product_current.PriceApplicableFrom, once silver_stage_dim_product propagates it into dim_product

        , null vendor_cost_unit                 -- Source once available: D365 InventPriceDisc.Amount or PurchLine.PurchPrice -- not yet ingested via BYOD
        , null vendor_id                        -- Source once available: bronze_d365_vendor_table.ACCOUNTNUM once joined through a pricing source -- vendor master alone has no item linkage
        , null vendor_name                      -- Source once available: bronze_d365_dir_party name, joined via bronze_d365_vendor_table -- not yet joined
        , null vendor_cost_effective_date       -- Source once available: D365 InventPriceDisc.FromDate or PurchLine posting date -- not yet ingested via BYOD

        , null plm_estimated_cost_unit          -- Source once available: silver_centric_product_current.FOBFullPrice, once silver_stage_dim_product propagates it into dim_product
        , c.plm_estimated_freight_unit
        , c.plm_estimated_duty_pct
        , c.plm_estimated_tariff_pct
        , null plm_cost_effective_date          -- Source once available: silver_centric_product_current.PriceApplicableFrom, once silver_stage_dim_product propagates it into dim_product

        , c.cost_currency_code
        , null fx_rate_to_usd                   -- Phase 2 -- source: FX rate table, not yet ingested
        , null standard_cost_unit_usd           -- Phase 2 -- computed as standard_cost_unit * fx_rate_to_usd once available
        , null landed_cost_unit_usd             -- Phase 2
        , null vendor_cost_unit_usd             -- Phase 2

        , cast(1 as boolean)                     as is_current    -- Trivially true for every row today -- becomes meaningful once history-accumulation logic is built (spec Open Decision #2)
        , 'Active'                               as cost_status

        , null prior_standard_cost_unit         -- Source once available: prior fact_product_cost row's standard_cost_unit for this product_id, once history-accumulation logic is built
        , null cost_change_amount               -- Source once available: standard_cost_unit minus prior_standard_cost_unit, once history-accumulation logic is built
        , null cost_change_pct                  -- Source once available: cost_change_amount / prior_standard_cost_unit x 100, once history-accumulation logic is built
        , null change_reason_code               -- Phase 2 -- source: manual entry or D365 cost adjustment reason, not yet captured

        , current_timestamp()                    as etl_insert_datetime
        , current_timestamp()                    as etl_update_datetime
        , sha2(
            concat_ws('||',
                coalesce(c.product_id, ''),
                coalesce(cast(c.standard_cost_unit as string), ''),
                coalesce(cast(c.landed_cost_unit as string), ''),
                coalesce(cast(c.freight_cost_unit as string), ''),
                coalesce(cast(c.duty_cost_unit as string), ''),
                coalesce(cast(c.tariff_cost_unit as string), '')
            ), 256
          )                                       as row_hash

    from combined c

)

select * from final