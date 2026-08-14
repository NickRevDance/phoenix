{{ config(materialized = 'table') }}

SELECT
    pc.*
    , p.product_key
FROM
    {{ref("silver_d365_inventory_product_cost")}} pc
    left join {{ref("dim_product")}} p
        on pc.ITEMID = p.product_id
        and version_number = 1