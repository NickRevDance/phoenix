{{ config(alias = 'bigcommerce_brand') }}

select
    s.*
from {{ ref('silver_bigcommerce_brand') }} as s
