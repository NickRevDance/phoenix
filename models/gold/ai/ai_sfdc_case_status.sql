{{ config(alias = 'sfdc_case_status') }}

select
    s.*
from {{ ref('bronze_sfdc_case_status') }} as s
