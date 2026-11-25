{{ config(alias = 'bigcommerce_orders') }}

select
    s.*
from {{ ref('silver_bigcommerce_orders') }} as s
