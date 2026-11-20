{{ config(alias = 'sfdc_event') }}

select
    s.*
from {{ ref('bronze_sfdc_event') }} as s
