{{ config(alias = 'bigcommerce_order_refund') }}

select
    s.*
from {{ ref('silver_bigcommerce_order_refund') }} as s
