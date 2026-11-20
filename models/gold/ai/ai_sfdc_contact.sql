{{ config(alias = 'sfdc_contact') }}

select
    s.*
from {{ ref('bronze_sfdc_contact') }} as s
