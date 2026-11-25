{{ config(alias = 'bigcommerce_order_product_option') }}

select
    s.*
from {{ ref('silver_bigcommerce_order_product_option') }} as s
