{{ config(alias = 'sfdc_rma_line_c') }}

select
    s.*
from {{ ref('bronze_sfdc_rma_line_c') }} as s
