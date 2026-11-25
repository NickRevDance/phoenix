{{ config(alias = 'bigcommerce_order_refund_item') }}

select
    s.*
from {{ ref('silver_bigcommerce_order_refund_item') }} as s
