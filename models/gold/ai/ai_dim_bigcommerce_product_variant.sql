{{ config(alias = 'dim_bigcommerce_product_variant') }}

select
    g.*
from {{ ref('dim_bigcommerce_product_variant') }} as g
