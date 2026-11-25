{{ config(alias = 'fact_bigcommerce_order_line') }}

select
    g.*
from {{ ref('fact_bigcommerce_order_line') }} as g
