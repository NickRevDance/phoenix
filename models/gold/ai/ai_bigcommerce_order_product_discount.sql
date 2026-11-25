{{ config(alias = 'bigcommerce_order_product_discount') }}

select
    s.*
from {{ ref('silver_bigcommerce_order_product_discount') }} as s
