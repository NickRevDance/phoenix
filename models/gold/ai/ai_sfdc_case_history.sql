{{ config(alias = 'sfdc_case_history') }}

select
    s.*
from {{ ref('bronze_sfdc_case_history') }} as s
