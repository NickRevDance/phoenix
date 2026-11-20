{{ config(alias = 'sfdc_case_contact_role') }}

select
    s.*
from {{ ref('silver_sfdc_case_contact_role') }} as s
