{{ config(alias = 'bigcommerce_order_coupon') }}

select
    s.*
from {{ ref('silver_bigcommerce_order_coupon') }} as s
