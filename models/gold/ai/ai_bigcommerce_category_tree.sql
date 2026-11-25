{{ config(alias = 'bigcommerce_category_tree') }}

select
    s.*
from {{ ref('silver_bigcommerce_category_tree') }} as s
