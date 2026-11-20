{{ config(alias = 'sfdc_case_contact_role') }}

select
    s.*
from {{ ref('bronze_sfdc_case_contact_role') }} as s
