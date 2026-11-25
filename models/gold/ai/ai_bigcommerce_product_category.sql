{{ config(alias = 'bigcommerce_product_category') }}

select
    s.*
from {{ ref('silver_bigcommerce_product_category') }} as s
