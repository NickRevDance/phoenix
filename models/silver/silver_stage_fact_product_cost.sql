{{ config(materialized = 'table') }}

WITH dim_product_by_item as (

    -- dim_product's real grain is product_key (UPC/colorway), many-to-one
    -- with product_id (the D365 item) -- dedupe down to one row per
    -- product_id before joining, since this fact's business key is
    -- product_id-level. See dbt_build_conventions's note on native/joined
    -- grain not always matching the target grain.
    SELECT

          product_id
        , product_key
        , SKU as sku
        , currency_code
        , plm_estimated_landed_cost
        , duty_percentage
        , tariff_percent
        , effective_start_datetime
        , row_number() over (partition by product_id order by product_key) as rn

    FROM {{ ref('dim_product') }}
    WHERE version_number = 1

),

shipment_cost_by_item as (

    -- Real per-unit freight/brokerage cost from D365's voyage-level landed-
    -- cost allocation (silver_d365_voyage_cost). Replaces the earlier
    -- ItmCostTrans+InventTrans-joined CTE: this source carries ITEMID
    -- directly (no join needed) and covers roughly 2x the Ocean/Air/Land
    -- rows ItmCostTrans did (see COMPLIANCE_REVIEW.md addendum, 2026-09-02).
    SELECT

          ITEMID as product_id
        , sum(case when SHIPCOSTTYPEID in ('Ocean', 'Air', 'Land') then SHIPACTUALCOST else 0 end)
            / nullif(sum(case when SHIPCOSTTYPEID in ('Ocean', 'Air', 'Land') then SHIPQTY else 0 end), 0) as freight_cost_unit
        , sum(case when SHIPCOSTTYPEID = 'Commission' then SHIPACTUALCOST else 0 end)
            / nullif(sum(case when SHIPCOSTTYPEID = 'Commission' then SHIPQTY else 0 end), 0) as brokerage_cost_unit
        , max(ALLOCATEDATE) as shipment_cost_update_datetime

    FROM {{ ref('silver_d365_voyage_cost') }}
    WHERE SHIPACTUALCOST <> 0
        and SHIPQTY > 0
        and ITEMID is not null
    GROUP BY ITEMID

),

vendor_price_current as (

    -- One currently-valid trade-agreement price per item: for the ~7% of
    -- items with more than one vendor agreement active at once, picks the
    -- most-recently-modified row as "current" -- NEEDS CONFIRMATION with
    -- Nick/Purchasing if a different tie-break (e.g. preferred vendor)
    -- should win instead.
    SELECT

          p.ITEMRELATION as product_id
        , p.ACCOUNTRELATION as vendor_id
        , cast(p.AMOUNT as decimal(19,4)) as vendor_cost_unit
        , p.CURRENCY as cost_currency_code
        , cast(p.FROMDATE as date) as effective_date
        , p.MODIFIEDDATE as d365_cost_update_datetime
        , row_number() over (
            partition by p.ITEMRELATION
            order by p.MODIFIEDDATE desc
          ) as rn

    FROM {{ ref('silver_d365_price_disc_table') }} p
    WHERE p.AMOUNT <> 0
        and p.ACCOUNTRELATION <> ''  -- ~89% of MODULE=2 rows have no vendor at all (a generic item price, not vendor-specific) -- excluded here since this cost_type is specifically vendor cost
        and (p.TODATE is null or p.TODATE >= current_date() or p.TODATE = date('1900-01-01'))
        and (p.FROMDATE is null or p.FROMDATE <= current_date())

),

standard_cost as (

    SELECT

          s.ITEMID as product_id
        , 'D365' as source_system
        , 'STANDARD' as cost_type
        , cast(null as string) as cost_subtype  -- Phase 2
        , 'Standard' as cost_method
        , cast(s.PRICEDATE as date) as effective_date
        , s.MODIFIEDDATE as d365_cost_update_datetime

        , cast(s.PRICE as decimal(19,4)) as standard_cost_unit
        , cast(null as decimal(19,4)) as landed_cost_unit
        , cast(null as decimal(19,4)) as freight_cost_unit  -- Source once available: dim_product.plm_estimated_freight_rate is a rate, not a $/unit amount -- no $/unit freight source yet, Open Decision #3
        , cast(null as decimal(19,4)) as duty_cost_unit  -- Phase 2 -- dim_product.duty_calculated exists but is held to the spec's Phase 2 tag
        , cast(null as decimal(19,4)) as tariff_cost_unit  -- Phase 2 -- dim_product.tariff_calculated exists but is held to the spec's Phase 2 tag
        , cast(null as decimal(19,4)) as brokerage_cost_unit  -- Source once available: no brokerage column on the Centric PLM export, Open Decision #3
        , cast(null as decimal(19,4)) as other_landed_cost_unit  -- Source once available: silver_centric_product_current.CommissionPerItem, once wired into dim_product
        , cast(null as decimal(19,4)) as vendor_cost_unit  -- Source once available: D365 InventPriceDisc/PurchLine, not yet ingested via BYOD
        , cast(null as string) as vendor_id
        , cast(null as string) as vendor_name
        , cast(null as decimal(19,4)) as plm_estimated_cost_unit
        , cast(null as decimal(19,4)) as plm_estimated_freight_unit
        , cast(null as decimal(9,4)) as plm_estimated_duty_pct
        , cast(null as decimal(9,4)) as plm_estimated_tariff_pct

        , p.currency_code as cost_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd  -- Phase 2
        , cast(null as decimal(19,4)) as standard_cost_unit_usd  -- Phase 2
        , cast(null as decimal(19,4)) as landed_cost_unit_usd  -- Phase 2
        , cast(null as decimal(19,4)) as vendor_cost_unit_usd  -- Phase 2

        , cast(null as string) as change_reason_code  -- Phase 2
        , cast(null as string) as d365_item_cost_id  -- Source once available: D365 InventCostPrice, not yet ingested via BYOD
        , cast(null as string) as d365_cost_group  -- Source once available: bronze_inventory_item.COSTGROUPID, join not built yet
        , cast(null as string) as d365_cost_version  -- Source once available: D365 InventCostPrice.CostingVersionId, not yet ingested via BYOD
        , 'silver_d365_inventory_product_cost' as record_source_table

        , p.product_key
        , p.sku

    FROM {{ ref('silver_d365_inventory_product_cost') }} s
    LEFT JOIN dim_product_by_item p
        ON p.product_id = s.ITEMID
        and p.rn = 1

),

landed_cost as (

    SELECT

          p.product_id
        , case when p.plm_estimated_landed_cost is not null then 'PLM' else 'D365' end as source_system
        , 'LANDED' as cost_type
        , cast(null as string) as cost_subtype
        , cast(null as string) as cost_method
        , coalesce(cast(p.effective_start_datetime as date), cast(sc.shipment_cost_update_datetime as date)) as effective_date
        , sc.shipment_cost_update_datetime as d365_cost_update_datetime

        , cast(null as decimal(19,4)) as standard_cost_unit
        , cast(p.plm_estimated_landed_cost as decimal(19,4)) as landed_cost_unit  -- populated from the PLM estimate while landed-cost components remain unsourced, per spec section 7
        , cast(sc.freight_cost_unit as decimal(19,4)) as freight_cost_unit  -- Source: D365 voyage-cost allocation (Ocean/Air/Land), $/unit averaged over allocation history -- closes Open Decision #3's freight gap
        , cast(null as decimal(19,4)) as duty_cost_unit  -- Phase 2 -- dim_product.duty_calculated exists, and silver_d365_voyage_cost carries a real, more complete Duty ship cost type (46,056 rows, avg $3.99/unit) than ItmCostTrans did -- still NEEDS CONFIRMATION before wiring in, not done unilaterally
        , cast(null as decimal(19,4)) as tariff_cost_unit  -- Phase 2
        , cast(sc.brokerage_cost_unit as decimal(19,4)) as brokerage_cost_unit  -- Source: D365 voyage-cost allocation Commission ship cost type, $/unit averaged over allocation history
        , cast(null as decimal(19,4)) as other_landed_cost_unit
        , cast(null as decimal(19,4)) as vendor_cost_unit
        , cast(null as string) as vendor_id
        , cast(null as string) as vendor_name
        , cast(null as decimal(19,4)) as plm_estimated_cost_unit
        , cast(null as decimal(19,4)) as plm_estimated_freight_unit
        , cast(null as decimal(9,4)) as plm_estimated_duty_pct
        , cast(null as decimal(9,4)) as plm_estimated_tariff_pct

        , p.currency_code as cost_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd
        , cast(null as decimal(19,4)) as standard_cost_unit_usd
        , cast(null as decimal(19,4)) as landed_cost_unit_usd
        , cast(null as decimal(19,4)) as vendor_cost_unit_usd

        , cast(null as string) as change_reason_code
        , cast(null as string) as d365_item_cost_id
        , cast(null as string) as d365_cost_group
        , cast(null as string) as d365_cost_version
        , case
            when sc.product_id is not null and p.plm_estimated_landed_cost is not null then 'dim_product+silver_d365_voyage_cost'
            when sc.product_id is not null then 'silver_d365_voyage_cost'
            else 'dim_product'
          end as record_source_table

        , p.product_key
        , p.sku

    FROM dim_product_by_item p
    LEFT JOIN shipment_cost_by_item sc
        ON sc.product_id = p.product_id
    WHERE p.rn = 1
        and (p.plm_estimated_landed_cost is not null or sc.product_id is not null)  -- emit a LANDED row when PLM gave an estimate OR real D365 shipment cost data exists

),

plm_estimated_cost as (

    SELECT

          p.product_id
        , 'PLM' as source_system
        , 'PLM_ESTIMATED' as cost_type
        , cast(null as string) as cost_subtype
        , cast(null as string) as cost_method
        , cast(p.effective_start_datetime as date) as effective_date
        , cast(null as timestamp) as d365_cost_update_datetime

        , cast(null as decimal(19,4)) as standard_cost_unit
        , cast(null as decimal(19,4)) as landed_cost_unit
        , cast(null as decimal(19,4)) as freight_cost_unit
        , cast(null as decimal(19,4)) as duty_cost_unit
        , cast(null as decimal(19,4)) as tariff_cost_unit
        , cast(null as decimal(19,4)) as brokerage_cost_unit
        , cast(null as decimal(19,4)) as other_landed_cost_unit
        , cast(null as decimal(19,4)) as vendor_cost_unit
        , cast(null as string) as vendor_id
        , cast(null as string) as vendor_name
        , cast(null as decimal(19,4)) as plm_estimated_cost_unit  -- Source once available: silver_centric_product_current.FOBFullPrice, once wired into dim_product
        , cast(null as decimal(19,4)) as plm_estimated_freight_unit  -- dim_product.plm_estimated_freight_rate is a rate, not a $/unit amount -- no $/unit freight source yet, Open Decision #3
        , cast(p.duty_percentage as decimal(9,4)) as plm_estimated_duty_pct
        , cast(p.tariff_percent as decimal(9,4)) as plm_estimated_tariff_pct

        , p.currency_code as cost_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd
        , cast(null as decimal(19,4)) as standard_cost_unit_usd
        , cast(null as decimal(19,4)) as landed_cost_unit_usd
        , cast(null as decimal(19,4)) as vendor_cost_unit_usd

        , cast(null as string) as change_reason_code
        , cast(null as string) as d365_item_cost_id
        , cast(null as string) as d365_cost_group
        , cast(null as string) as d365_cost_version
        , 'dim_product' as record_source_table

        , p.product_key
        , p.sku

    FROM dim_product_by_item p
    WHERE p.rn = 1
        and (p.duty_percentage is not null or p.tariff_percent is not null)  -- only emit a PLM_ESTIMATED row where PLM gave us something to track

),

vendor_cost as (

    -- Real VENDOR cost_type rows from D365 PriceDiscTable (native vendor
    -- trade agreements) -- closes the "no VENDOR rows" gap; previously this
    -- cost_type had no source data to iterate over at all.
    SELECT

          v.product_id
        , 'D365' as source_system
        , 'VENDOR' as cost_type
        , cast(null as string) as cost_subtype
        , 'Trade Agreement' as cost_method
        , v.effective_date
        , v.d365_cost_update_datetime

        , cast(null as decimal(19,4)) as standard_cost_unit
        , cast(null as decimal(19,4)) as landed_cost_unit
        , cast(null as decimal(19,4)) as freight_cost_unit
        , cast(null as decimal(19,4)) as duty_cost_unit  -- Phase 2
        , cast(null as decimal(19,4)) as tariff_cost_unit  -- Phase 2
        , cast(null as decimal(19,4)) as brokerage_cost_unit
        , cast(null as decimal(19,4)) as other_landed_cost_unit
        , v.vendor_cost_unit
        , v.vendor_id
        , dv.vendor_name

        , cast(null as decimal(19,4)) as plm_estimated_cost_unit
        , cast(null as decimal(19,4)) as plm_estimated_freight_unit
        , cast(null as decimal(9,4)) as plm_estimated_duty_pct
        , cast(null as decimal(9,4)) as plm_estimated_tariff_pct

        , v.cost_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd  -- Phase 2
        , cast(null as decimal(19,4)) as standard_cost_unit_usd  -- Phase 2
        , cast(null as decimal(19,4)) as landed_cost_unit_usd  -- Phase 2
        , cast(null as decimal(19,4)) as vendor_cost_unit_usd  -- Phase 2

        , cast(null as string) as change_reason_code  -- Phase 2
        , cast(null as string) as d365_item_cost_id
        , cast(null as string) as d365_cost_group
        , cast(null as string) as d365_cost_version
        , 'silver_d365_price_disc_table' as record_source_table

        , p.product_key
        , p.sku

    FROM vendor_price_current v
    LEFT JOIN dim_product_by_item p
        ON p.product_id = v.product_id
        and p.rn = 1
    LEFT JOIN {{ ref('silver_stage_dim_vendor') }} dv
        ON dv.vendor_id = v.vendor_id
        and dv.source_system = 'D365'
    WHERE v.rn = 1

),

combined as (

    SELECT * FROM standard_cost
    UNION ALL
    SELECT * FROM landed_cost
    UNION ALL
    SELECT * FROM plm_estimated_cost
    UNION ALL
    SELECT * FROM vendor_cost

)

SELECT
      c.*
    -- business key minus effective_date -- the SCD2 entity a new cost record versions against
    , md5(concat_ws('|', c.product_id, c.cost_type, c.source_system)) as product_cost_entity_key
    -- change hash over every field that should trigger a new version when it changes
    , sha2(
        concat_ws('||',
            coalesce(cast(c.standard_cost_unit as string), ''),
            coalesce(cast(c.landed_cost_unit as string), ''),
            coalesce(cast(c.freight_cost_unit as string), ''),
            coalesce(cast(c.duty_cost_unit as string), ''),
            coalesce(cast(c.tariff_cost_unit as string), ''),
            coalesce(cast(c.brokerage_cost_unit as string), ''),
            coalesce(cast(c.other_landed_cost_unit as string), ''),
            coalesce(cast(c.vendor_cost_unit as string), ''),
            coalesce(c.vendor_id, ''),
            coalesce(cast(c.plm_estimated_cost_unit as string), ''),
            coalesce(cast(c.plm_estimated_freight_unit as string), ''),
            coalesce(cast(c.plm_estimated_duty_pct as string), ''),
            coalesce(cast(c.plm_estimated_tariff_pct as string), ''),
            coalesce(c.cost_currency_code, '')
        ), 256
      ) as cost_change_hash
FROM combined c
