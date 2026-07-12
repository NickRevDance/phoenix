{{ config(materialized = 'table') }}

SELECT
    s.*
    , p.product_dim_id
FROM
    {{ref("silver_byod_inventory_sum")}} s
    left join {{ref("dim_product")}} p
		on s.ITEMID = p.StyleNumber
		and s.INVENTSIZEID = p.Size
		and s.INVENTCOLORID = p.D365ColorCode