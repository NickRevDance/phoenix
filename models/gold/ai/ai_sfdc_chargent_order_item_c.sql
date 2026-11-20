{{ config(alias = 'sfdc_chargent_order_item_c') }}

select
    s.*
from {{ ref('bronze_sfdc_chargent_order_item_c') }} as s
