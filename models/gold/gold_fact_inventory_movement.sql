{{ config(materialized = 'table') }}

SELECT
    date(t.DATEPHYSICAL) as movement_date
    , p.product_key
    , w.warehouse_key
    , t.ReferenceCategory as transaction_type
    , SUM(t.QTY) AS net_qty_movement
FROM 
    {{ref("silver_byod_inventory_trans")}} t
    JOIN {{ref("silver_byod_inventory_dim")}} d ON t.INVENTDIMID = d.INVENTDIMID
    left join {{ref("gold_dim_warehouse")}} w 
        ON d.INVENTSITEID = w.site_id
        and d.INVENTLOCATIONID = w.warehouse_id
    left join {{ref("gold_v_dim_product")}} p on t.ITEMID = p.product_id
GROUP BY 
    date(t.DATEPHYSICAL)
    , p.product_key
    , w.warehouse_key
    , t.ReferenceCategory