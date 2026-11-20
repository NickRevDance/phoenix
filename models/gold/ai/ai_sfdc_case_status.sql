{{ config(alias = 'sfdc_case_status') }}

select
    s.*
from {{ ref('silver_sfdc_case_status') }} as s
