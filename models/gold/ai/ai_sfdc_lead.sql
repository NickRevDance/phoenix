{{ config(alias = 'sfdc_lead') }}

select
    s.*
from {{ ref('bronze_sfdc_lead') }} as s
