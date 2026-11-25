{{ config(alias = 'bigcommerce_product_variant') }}

select
    s.*
from {{ ref('silver_bigcommerce_product_variant') }} as s
