-- EDW-49: retail_value_amount = on_hand_qty x current USD list price (spec 2.3 derivation test).
-- Checked on the latest native snapshot only: earlier days were priced at their own load.

with latest as (

    select max(f.snapshot_date) as snapshot_date
    from {{ ref('fact_inventory_snapshot_daily') }} f
    where f.record_source_table = {{ inventory_snapshot_branch_label('native') }}

),

checked as (

    select

          f.inventory_snapshot_key
        , f.product_key
        , f.on_hand_qty
        , f.retail_value_amount
        , cast(f.on_hand_qty * p.list_price_usd as decimal(19,4)) as expected_retail_value_amount

    from {{ ref('fact_inventory_snapshot_daily') }} f
    inner join latest l
        on f.snapshot_date = l.snapshot_date
    left join {{ ref('v_product_price_current') }} p
        on f.product_key = p.product_key
    where f.record_source_table = {{ inventory_snapshot_branch_label('native') }}

)

select c.*
from checked c
where not (c.retail_value_amount <=> c.expected_retail_value_amount)
