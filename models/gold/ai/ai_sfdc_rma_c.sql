{{ config(alias = 'sfdc_rma_c') }}

select
    s.*
from {{ ref('bronze_sfdc_rma_c') }} as s
