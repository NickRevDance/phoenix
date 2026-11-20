{{ config(alias = 'sfdc_sales_product_c') }}

select
    s.*
from {{ ref('silver_sfdc_sales_product_c') }} as s
