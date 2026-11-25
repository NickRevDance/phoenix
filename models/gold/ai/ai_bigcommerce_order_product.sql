{{ config(alias = 'bigcommerce_order_product') }}

select
    s.*
from {{ ref('silver_bigcommerce_order_product') }} as s
