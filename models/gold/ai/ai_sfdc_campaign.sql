{{ config(alias = 'sfdc_campaign') }}

select
    s.*
from {{ ref('bronze_sfdc_campaign') }} as s
