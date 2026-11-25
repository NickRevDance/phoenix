{{ config(alias = 'bigcommerce_store') }}

select
    s.*
from {{ ref('silver_bigcommerce_store') }} as s
