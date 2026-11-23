{{ config(severity = 'warn') }}

-- EDW-69: shipped quantity per sales line on FACT_SHIPMENT matches the posted packing slip quantity (99.95% on
-- the Nov 10 profile). Lines shipped in the last 3 days are skipped while their packing slips post.
-- EDW-196: FY27 forward only (last ship date on or after Jul 1 2026). The 51 lines before that (Nov 2023 to
-- Apr 2024, an older pattern where the slip exceeds WMS shipped or has no slip) stay visible in the facts but
-- no longer hold the warning's floor, so the count reads new problems.

with shipped as (

    select
          f.d365_sales_line_rec_id
        , sum(f.shipped_qty) as shipped_qty
        , max(f.ship_date) as last_ship_date
    from {{ ref('fact_shipment') }} f
    where f.shipment_status = 'Picked Up'
      and f.d365_sales_line_rec_id is not null
    group by f.d365_sales_line_rec_id

),

slipped as (

    select
          sl.REC as d365_sales_line_rec_id
        , sum(pst.QTY) as packing_slip_qty
    from {{ ref('silver_d365_cust_packing_slip_trans') }} pst
    inner join {{ ref('silver_d365_sales_line') }} sl
        on sl.INVENTTRANSID = pst.INVENTTRANSID
    where pst.QTY > 0
    group by sl.REC

)

select
      s.d365_sales_line_rec_id
    , s.shipped_qty
    , p.packing_slip_qty
from shipped s
left join slipped p
    on p.d365_sales_line_rec_id = s.d365_sales_line_rec_id
where s.last_ship_date < date_sub(current_date(), 3)
  and s.last_ship_date >= date'2026-07-01'
  and coalesce(p.packing_slip_qty, 0) <> s.shipped_qty