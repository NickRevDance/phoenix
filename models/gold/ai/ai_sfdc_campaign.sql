{{ config(alias = 'sfdc_campaign') }}

select
    s.*
from {{ ref('silver_sfdc_campaign') }} as s
