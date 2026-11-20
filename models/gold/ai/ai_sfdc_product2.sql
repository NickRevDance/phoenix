{{ config(alias = 'sfdc_product2') }}

select
    s.*
from {{ ref('silver_sfdc_product2') }} as s
