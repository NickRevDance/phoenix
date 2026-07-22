{{ config(materialized = 'table') }}

SELECT
    s.*
    , p.product_key
FROM
    {{ref("silver_byod_inventory_sum")}} s
    left join {{ref("dim_product")}} p
		on s.ITEMID = p.style_number
		and s.INVENTSIZEID = p.size
		and s.INVENTCOLORID = p.d365_color_code