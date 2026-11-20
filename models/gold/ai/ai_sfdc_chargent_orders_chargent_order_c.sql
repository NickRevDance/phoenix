{{ config(alias = 'sfdc_chargent_orders_chargent_order_c') }}

select
    s.*
from {{ ref('silver_sfdc_chargent_orders_chargent_order_c') }} as s
