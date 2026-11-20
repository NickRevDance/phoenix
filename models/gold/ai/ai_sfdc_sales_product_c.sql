{{ config(alias = 'sfdc_sales_product_c') }}

select
    s.*
from {{ ref('bronze_sfdc_sales_product_c') }} as s
