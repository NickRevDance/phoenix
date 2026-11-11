{{ config(severity = 'warn') }}

-- EDW-90 (DIM_WAREHOUSE spec Section 6, Open Decision 7 trigger): a fact warehouse_key that isn't in
-- v_dim_warehouse_current. Fact attribution is still correct (facts resolve on the latest version);
-- this flags a warehouse that has left the source while facts still reference it.

with fact_keys as (

    select distinct warehouse_key, 'fact_inventory_snapshot_daily' as fact_name from {{ ref('fact_inventory_snapshot_daily') }}
    union
    select distinct warehouse_key, 'fact_inventory_movement' from {{ ref('fact_inventory_movement') }}
    union
    select distinct from_warehouse_key, 'fact_inventory_movement' from {{ ref('fact_inventory_movement') }}
    union
    select distinct to_warehouse_key, 'fact_inventory_movement' from {{ ref('fact_inventory_movement') }}
    union
    select distinct warehouse_key, 'fact_purchase_order' from {{ ref('fact_purchase_order') }}
    union
    select distinct warehouse_key, 'fact_order_line' from {{ ref('fact_order_line') }}
    union
    select distinct warehouse_key, 'fact_orders_returns' from {{ ref('fact_orders_returns') }}
    union
    select distinct warehouse_key, 'fact_sales_invoice' from {{ ref('fact_sales_invoice') }}
    union
    select distinct warehouse_key, 'fact_inventory_quality_code_color_daily' from {{ ref('fact_inventory_quality_code_color_daily') }}    
    union
    select distinct warehouse_key, 'fact_shipment' from {{ ref('fact_shipment') }}

)

select
      f.fact_name
    , f.warehouse_key
from fact_keys f
left join {{ ref('v_dim_warehouse_current') }} c
    on f.warehouse_key = c.warehouse_key
where f.warehouse_key is not null
  and c.warehouse_key is null
