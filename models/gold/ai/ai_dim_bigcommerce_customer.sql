{{ config(alias = 'dim_bigcommerce_customer') }}

select
    g.*
from {{ ref('dim_bigcommerce_customer') }} as g
