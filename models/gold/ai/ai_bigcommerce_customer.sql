{{ config(alias = 'bigcommerce_customer') }}

select
    s.*
from {{ ref('silver_bigcommerce_customer') }} as s
