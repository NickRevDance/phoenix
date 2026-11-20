{{ config(alias = 'sfdc_case_comment') }}

select
    s.*
from {{ ref('bronze_sfdc_case_comment') }} as s
