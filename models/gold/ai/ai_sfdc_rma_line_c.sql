{{ config(alias = 'sfdc_rma_line_c') }}

select
    s.*
from {{ ref('silver_sfdc_rma_line_c') }} as s
