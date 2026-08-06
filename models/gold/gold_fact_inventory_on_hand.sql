{{ config(materialized = 'table') }}

SELECT
    w.warehouse_key
    , p.product_key
    , s.*
FROM
    {{ref("silver_byod_inventory_sum")}} s
    left join {{ref("gold_v_dim_product")}} p
		on s.ITEMID = p.style_number
		and s.INVENTSIZEID = p.size
		and s.INVENTCOLORID = p.d365_color_code
    left join {{ref("gold_dim_warehouse")}} w
        on s.INVENTLOCATIONID = w.warehouse_id
        and s.inventsiteid = w.site_id