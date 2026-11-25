{{ config(alias = 'bigcommerce_customer_group') }}

select
    s.*
from {{ ref('silver_bigcommerce_customer_group') }} as s
