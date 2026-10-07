{{ config(severity = 'warn', warn_if = '>0', error_if = '>100000') }}

-- EDW-134: D365 barcodes (EAN / Code 39) with no DIM_PRODUCT row. Their sales,
-- order and return lines carry product_key '-1' (Unknown) until the product
-- reaches Centric (or the agreed source). Warn-level by design: a known source
-- gap, not a pipeline defect. Returns one row per gap UPC on an item with D365
-- sales activity so the list can be worked by merchandising.
with gap as (

    select
        b.ITEMID
        , b.ITEMBARCODE as upc
    from {{ ref('silver_d365_item_barcode') }} b
    left join {{ ref('dim_product') }} p
        on md5(concat_ws('|', b.ITEMBARCODE)) = p.product_key
        and p.version_number = 1
    where p.product_key is null
      and b.ITEMBARCODE is not null

)

select g.*
from gap g
inner join {{ ref('silver_d365_sales_line') }} l
    on l.ITEMID = g.ITEMID
group by g.ITEMID, g.upc