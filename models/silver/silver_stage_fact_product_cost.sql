{{ config(materialized = 'table') }}

WITH dim_product_by_item as (

    -- dim_product's real grain is product_key (UPC/colorway), many-to-one
    -- with product_id (the D365 item) -- dedupe down to one row per
    -- product_id before joining, since this fact's business key is
    -- product_id-level.
    SELECT

          dp.product_id
        , dp.product_key
        , dp.SKU as sku
        , dp.currency_code
        , dp.plm_estimated_landed_cost
        , dp.plm_estimated_freight_rate
        , dp.duty_percentage
        , dp.duty_calculated
        , dp.tariff_percent
        , dp.tariff_calculated
        , cp.FOBFullPrice as plm_fob_full_price
        , dp.effective_start_datetime
        , row_number() over (partition by dp.product_id order by dp.product_key) as rn

    FROM {{ ref('dim_product') }} dp
    LEFT JOIN {{ ref('silver_dwh_centric_product_current') }} cp
        ON cp.UPC = dp.UPC
    WHERE dp.version_number = 1

),

voyage_lines as (

    -- One row per voyage line (shipment + PO transaction + item/colour/size),
    -- collapsing the cost-type rows. Goods value comes from the Duty row,
    -- any row otherwise. Zero-cost rows and the 1900-01-01 placeholder
    -- allocation date are excluded.
    SELECT

          v.ITEMID as product_id
        , v.SHIPID
        , v.TRANSREFID
        , v.INVENTCOLORID
        , v.INVENTSIZEID
        , max(v.ALLOCATEDATE) as allocate_date
        , max(v.SHIPQTY) as ship_qty
        , coalesce(
              max(case when v.SHIPCOSTTYPEID = 'Duty' then v.LINEAMOUNTMST end)
            , max(v.LINEAMOUNTMST)
          ) as goods_amount
        , sum(case when v.SHIPCOSTTYPEID in ('Ocean', 'Air', 'Land') then v.SHIPACTUALCOST else 0 end) as freight_amount
        , sum(case when v.SHIPCOSTTYPEID = 'Duty' then v.SHIPACTUALCOST else 0 end) as duty_amount
        , sum(case when v.SHIPCOSTTYPEID = 'Commission' then v.SHIPACTUALCOST else 0 end) as brokerage_amount

    FROM {{ ref('silver_d365_voyage_cost') }} v
    WHERE v.SHIPACTUALCOST <> 0
        and v.SHIPQTY > 0
        and v.ITEMID is not null
        and v.ALLOCATEDATE > timestamp('1900-01-01')
    GROUP BY v.ITEMID, v.SHIPID, v.TRANSREFID, v.INVENTCOLORID, v.INVENTSIZEID

),

voyage_item_anchor as (

    SELECT

          l.product_id
        , max(l.allocate_date) as latest_allocate_date

    FROM voyage_lines l
    GROUP BY l.product_id

),

landed_by_item as (

    -- Decision Record A4: quantity-weighted over the 365 days ending at the
    -- item's own latest allocation, so a row re-versions only when a new
    -- voyage lands.
    SELECT

          l.product_id
        , a.latest_allocate_date
        , sum(l.goods_amount) / sum(l.ship_qty) as goods_cost_unit
        , sum(l.freight_amount) / sum(l.ship_qty) as freight_cost_unit
        , sum(l.duty_amount) / sum(l.ship_qty) as duty_cost_unit
        , sum(l.brokerage_amount) / sum(l.ship_qty) as brokerage_cost_unit

    FROM voyage_lines l
    INNER JOIN voyage_item_anchor a
        ON a.product_id = l.product_id
    WHERE l.allocate_date > a.latest_allocate_date - interval 365 days
    GROUP BY l.product_id, a.latest_allocate_date

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
        , case when p.FROMDATE = date('1900-01-01') then cast(null as date) else cast(p.FROMDATE as date) end as effective_date  -- EDW-94 A4: 1900-01-01 is D365's unset-date placeholder, not a real date
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

standard_price_open as (

    SELECT

          p.ITEMRELATION as product_id
        , cast(p.AMOUNT as decimal(19,4)) as standard_cost_unit
        , p.CURRENCY as cost_currency_code
        , case when p.FROMDATE = date('1900-01-01') then cast(null as date) else cast(p.FROMDATE as date) end as effective_date  -- EDW-94 A4: 1900-01-01 is D365's unset-date placeholder, not a real date
        , p.MODIFIEDDATE as d365_cost_update_datetime
        , case when p.ACCOUNTRELATION = '' then 0 else 1 end as price_tier
        , p.AMOUNT as raw_amount
        , count(*) over (
            partition by p.ITEMRELATION, case when p.ACCOUNTRELATION = '' then 0 else 1 end, p.AMOUNT
          ) as variants_at_price

    FROM {{ ref('silver_d365_price_disc_table') }} p
    WHERE p.AMOUNT <> 0
        and (p.TODATE is null or p.TODATE >= current_date() or p.TODATE = date('1900-01-01'))
        and (p.FROMDATE is null or p.FROMDATE <= current_date())

),

standard_price_current as (

    -- Decision Record B4: generic (blank-vendor) tier first, vendor-specific
    -- only as fallback. Within the tier, the modal price across variants
    -- wins, ties to the lower price, then the latest modification.
    SELECT

          o.product_id
        , o.standard_cost_unit
        , o.cost_currency_code
        , o.effective_date
        , o.d365_cost_update_datetime
        , row_number() over (
            partition by o.product_id
            order by
                o.price_tier
              , o.variants_at_price desc
              , o.raw_amount asc
              , o.d365_cost_update_datetime desc
          ) as rn

    FROM standard_price_open o

),

standard_cost as (

    SELECT

          sp.product_id
        , 'D365' as source_system
        , 'STANDARD' as cost_type
        , 'PURCHASE_TRADE_AGREEMENT' as cost_subtype
        , 'Purchase Price' as cost_method  -- was 'Standard' -- source is PriceDiscTable purchase price, not a D365-computed standard cost, see standard_price_current
        , sp.effective_date
        , sp.d365_cost_update_datetime

        , sp.standard_cost_unit
        , cast(null as decimal(19,4)) as landed_cost_unit
        , cast(null as decimal(19,4)) as goods_cost_unit
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

        , coalesce(sp.cost_currency_code, p.currency_code) as cost_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd  -- Phase 2
        , cast(null as decimal(19,4)) as standard_cost_unit_usd  -- Phase 2
        , cast(null as decimal(19,4)) as landed_cost_unit_usd  -- Phase 2
        , cast(null as decimal(19,4)) as vendor_cost_unit_usd  -- Phase 2
        , cast(null as decimal(19,4)) as plm_estimated_cost_unit_usd  -- Phase 2

        , cast(null as string) as change_reason_code  -- Phase 2
        , cast(null as string) as d365_item_cost_id  -- Source once available: D365 InventCostPrice, not yet ingested via BYOD
        , cast(null as string) as d365_cost_group  -- Source once available: bronze_inventory_item.COSTGROUPID, join not built yet
        , cast(null as string) as d365_cost_version  -- Source once available: D365 InventCostPrice.CostingVersionId, not yet ingested via BYOD
        , 'silver_d365_price_disc_table' as record_source_table

        , p.product_key
        , p.sku

    FROM standard_price_current sp
    LEFT JOIN dim_product_by_item p
        ON p.product_id = sp.product_id
        and p.rn = 1
    WHERE sp.rn = 1

),

landed_cost as (

    -- D365 voyage actuals only (Decision Record A1). landed_cost_unit is the
    -- goods base plus the actual components, so the derivation holds exactly.
    SELECT

          lb.product_id
        , 'D365' as source_system
        , 'LANDED' as cost_type
        , 'VOYAGE_ACTUAL' as cost_subtype
        , cast(null as string) as cost_method
        , cast(lb.latest_allocate_date as date) as effective_date
        , lb.latest_allocate_date as d365_cost_update_datetime

        , cast(null as decimal(19,4)) as standard_cost_unit
        , cast(lb.goods_cost_unit as decimal(19,4))
            + coalesce(cast(lb.freight_cost_unit as decimal(19,4)), 0)
            + coalesce(cast(lb.duty_cost_unit as decimal(19,4)), 0)
            + coalesce(cast(lb.brokerage_cost_unit as decimal(19,4)), 0) as landed_cost_unit
        , cast(lb.goods_cost_unit as decimal(19,4)) as goods_cost_unit
        , cast(lb.freight_cost_unit as decimal(19,4)) as freight_cost_unit  -- Ocean/Air/Land
        , cast(lb.duty_cost_unit as decimal(19,4)) as duty_cost_unit  -- all-in customs charge; D365 does not split duty from tariffs
        , cast(null as decimal(19,4)) as tariff_cost_unit  -- see duty_cost_unit
        , cast(lb.brokerage_cost_unit as decimal(19,4)) as brokerage_cost_unit  -- Commission
        , cast(null as decimal(19,4)) as other_landed_cost_unit
        , cast(null as decimal(19,4)) as vendor_cost_unit
        , cast(null as string) as vendor_id
        , cast(null as string) as vendor_name
        , cast(null as decimal(19,4)) as plm_estimated_cost_unit
        , cast(null as decimal(19,4)) as plm_estimated_freight_unit
        , cast(null as decimal(9,4)) as plm_estimated_duty_pct
        , cast(null as decimal(9,4)) as plm_estimated_tariff_pct

        , coalesce(p.currency_code, 'USD') as cost_currency_code  -- voyage cost is booked in company currency
        , cast(null as decimal(19,8)) as fx_rate_to_usd
        , cast(null as decimal(19,4)) as standard_cost_unit_usd
        , cast(null as decimal(19,4)) as landed_cost_unit_usd
        , cast(null as decimal(19,4)) as vendor_cost_unit_usd
        , cast(null as decimal(19,4)) as plm_estimated_cost_unit_usd

        , cast(null as string) as change_reason_code
        , cast(null as string) as d365_item_cost_id
        , cast(null as string) as d365_cost_group
        , cast(null as string) as d365_cost_version
        , 'silver_d365_voyage_cost' as record_source_table

        , p.product_key
        , p.sku

    FROM landed_by_item lb
    LEFT JOIN dim_product_by_item p
        ON p.product_id = lb.product_id
        and p.rn = 1

),

plm_estimated_cost as (

    SELECT

          p.product_id
        , 'PLM' as source_system
        , 'PLM_ESTIMATED' as cost_type
        , 'PLM_ESTIMATE' as cost_subtype
        , cast(null as string) as cost_method
        , cast(p.effective_start_datetime as date) as effective_date
        , cast(null as timestamp) as d365_cost_update_datetime

        , cast(null as decimal(19,4)) as standard_cost_unit
        , cast(p.plm_estimated_landed_cost as decimal(19,4)) as landed_cost_unit  -- Centric estimate, never a LANDED source
        , cast(null as decimal(19,4)) as goods_cost_unit
        , cast(null as decimal(19,4)) as freight_cost_unit
        , cast(null as decimal(19,4)) as duty_cost_unit
        , cast(null as decimal(19,4)) as tariff_cost_unit
        , cast(null as decimal(19,4)) as brokerage_cost_unit
        , cast(null as decimal(19,4)) as other_landed_cost_unit
        , cast(null as decimal(19,4)) as vendor_cost_unit
        , cast(null as string) as vendor_id
        , cast(null as string) as vendor_name
        , cast(coalesce(
              p.plm_fob_full_price
            , p.plm_estimated_landed_cost
                - coalesce(p.plm_estimated_freight_rate, 0)
                - coalesce(p.duty_calculated, 0)
                - coalesce(p.tariff_calculated, 0)
          ) as decimal(19,4)) as plm_estimated_cost_unit  -- FOB: FOBFullPrice, else landed minus freight, duty and tariff
        , cast(p.plm_estimated_freight_rate as decimal(19,4)) as plm_estimated_freight_unit  -- $/unit amount, verified
        , cast(p.duty_percentage as decimal(9,4)) as plm_estimated_duty_pct
        , cast(p.tariff_percent as decimal(9,4)) as plm_estimated_tariff_pct

        , p.currency_code as cost_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd
        , cast(null as decimal(19,4)) as standard_cost_unit_usd
        , cast(null as decimal(19,4)) as landed_cost_unit_usd
        , cast(null as decimal(19,4)) as vendor_cost_unit_usd
        , cast(null as decimal(19,4)) as plm_estimated_cost_unit_usd

        , cast(null as string) as change_reason_code
        , cast(null as string) as d365_item_cost_id
        , cast(null as string) as d365_cost_group
        , cast(null as string) as d365_cost_version
        , 'dim_product' as record_source_table

        , p.product_key
        , p.sku

    FROM dim_product_by_item p
    WHERE p.rn = 1
        and (p.plm_estimated_landed_cost is not null or p.duty_percentage is not null or p.tariff_percent is not null)  -- only emit a PLM_ESTIMATED row where PLM gave us something to track

),

vendor_cost as (

    -- Real VENDOR cost_type rows from D365 PriceDiscTable (native vendor
    -- trade agreements) -- closes the "no VENDOR rows" gap; previously this
    -- cost_type had no source data to iterate over at all.
    SELECT

          v.product_id
        , 'D365' as source_system
        , 'VENDOR' as cost_type
        , 'VENDOR_TRADE_AGREEMENT' as cost_subtype
        , 'Trade Agreement' as cost_method
        , v.effective_date
        , v.d365_cost_update_datetime

        , cast(null as decimal(19,4)) as standard_cost_unit
        , cast(null as decimal(19,4)) as landed_cost_unit
        , cast(null as decimal(19,4)) as goods_cost_unit
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
        , cast(null as decimal(19,4)) as plm_estimated_cost_unit_usd  -- Phase 2

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

),

fx_applied as (

    -- EDW-94 Phase 2 USD normalization, covering all 4 cost_type values
    -- (STANDARD/LANDED/VENDOR/PLM_ESTIMATED -- EDW-94's AC requires "all
    -- cost types", so plm_estimated_cost_unit_usd is included even though
    -- PLM_ESTIMATED rows are USD-only in practice today). Joins D365's own
    -- spot rate (silver_d365_exchange_rate) by currency + the rate's valid
    -- date range, keyed off this row's own effective_date (falling back to
    -- its D365 update timestamp, then today, when effective_date is null).
    -- USD rows (100% of live data today) get an identity 1.0 rate without a
    -- lookup; a currency with no exchange-rate row on file (anything but
    -- CAD/GBP today) stays null rather than guessing. Deliberately NOT part
    -- of cost_change_hash below -- a currency's rate drifting month to
    -- month shouldn't version this row's cost history on its own.
    SELECT

          c.* EXCEPT (fx_rate_to_usd, standard_cost_unit_usd, landed_cost_unit_usd, vendor_cost_unit_usd, plm_estimated_cost_unit_usd)
        , case
            when c.cost_currency_code = 'USD' then cast(1 as decimal(19,8))
            else fx.fx_rate_to_usd
          end as fx_rate_to_usd
        , case
            when c.cost_currency_code = 'USD' then c.standard_cost_unit
            when fx.fx_rate_to_usd is not null then c.standard_cost_unit * fx.fx_rate_to_usd
          end as standard_cost_unit_usd
        , case
            when c.cost_currency_code = 'USD' then c.landed_cost_unit
            when fx.fx_rate_to_usd is not null then c.landed_cost_unit * fx.fx_rate_to_usd
          end as landed_cost_unit_usd
        , case
            when c.cost_currency_code = 'USD' then c.vendor_cost_unit
            when fx.fx_rate_to_usd is not null then c.vendor_cost_unit * fx.fx_rate_to_usd
          end as vendor_cost_unit_usd
        , case
            when c.cost_currency_code = 'USD' then c.plm_estimated_cost_unit
            when fx.fx_rate_to_usd is not null then c.plm_estimated_cost_unit * fx.fx_rate_to_usd
          end as plm_estimated_cost_unit_usd

    FROM combined c
    LEFT JOIN {{ ref('silver_d365_exchange_rate') }} fx
        ON fx.from_currency_code = c.cost_currency_code
        and coalesce(c.effective_date, cast(c.d365_cost_update_datetime as date), current_date())
            between fx.valid_from_date and fx.valid_to_date

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
            coalesce(cast(c.goods_cost_unit as string), ''),
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
            coalesce(c.cost_currency_code, ''),
            coalesce(c.cost_subtype, '')
        ), 256
      ) as cost_change_hash
FROM fx_applied c
