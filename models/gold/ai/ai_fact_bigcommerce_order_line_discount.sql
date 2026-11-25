{{ config(alias = 'fact_bigcommerce_order_line_discount') }}

select
    g.*
from {{ ref('fact_bigcommerce_order_line_discount') }} as g
