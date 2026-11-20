{{ config(alias = 'sfdc_product2') }}

select
    s.*
from {{ ref('bronze_sfdc_product2') }} as s
