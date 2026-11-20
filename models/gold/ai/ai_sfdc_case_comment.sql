{{ config(alias = 'sfdc_case_comment') }}

select
    s.*
from {{ ref('silver_sfdc_case_comment') }} as s
