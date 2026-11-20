{{ config(alias = 'sfdc_case_history') }}

select
    s.*
from {{ ref('silver_sfdc_case_history') }} as s
