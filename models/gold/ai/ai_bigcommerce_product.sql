{{ config(alias = 'bigcommerce_product') }}

select
    s.*
from {{ ref('silver_bigcommerce_product') }} as s
