{{ config(alias = 'fact_bigcommerce_order') }}

select
    g.*
from {{ ref('fact_bigcommerce_order') }} as g
