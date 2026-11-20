{{ config(alias = 'sfdc_rma_c') }}

select
    s.*
from {{ ref('silver_sfdc_rma_c') }} as s
