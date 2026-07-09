{{ config(materialized = 'table') }}

SELECT
    s.*
    , p.product_dim_id
FROM
    {{ref("silver_byod_inventory_sum")}} s
    left join {{ref("dim_product")}} p
        on s.ItemID = p.ItemID
        and s.InventDimID = p.InventDimID