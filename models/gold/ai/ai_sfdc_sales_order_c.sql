{{ config(alias = 'sfdc_sales_order_c') }}

select
    s.*
from {{ ref('bronze_sfdc_sales_order_c') }} as s
