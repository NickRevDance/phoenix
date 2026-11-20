{{ config(alias = 'sfdc_sales_order_c') }}

select
    s.*
from {{ ref('silver_sfdc_sales_order_c') }} as s
