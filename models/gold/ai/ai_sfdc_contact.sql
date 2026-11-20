{{ config(alias = 'sfdc_contact') }}

select
    s.*
from {{ ref('silver_sfdc_contact') }} as s
