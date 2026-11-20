{{ config(alias = 'sfdc_event') }}

select
    s.*
from {{ ref('silver_sfdc_event') }} as s
