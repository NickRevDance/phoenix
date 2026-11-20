{{ config(alias = 'sfdc_lead') }}

select
    s.*
from {{ ref('silver_sfdc_lead') }} as s
