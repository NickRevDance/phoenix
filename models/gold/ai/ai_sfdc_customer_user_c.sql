{{ config(alias = 'sfdc_customer_user_c') }}

select
    s.*
from {{ ref('bronze_sfdc_customer_user_c') }} as s
