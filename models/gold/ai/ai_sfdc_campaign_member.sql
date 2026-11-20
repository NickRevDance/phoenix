{{ config(alias = 'sfdc_campaign_member') }}

select
    s.*
from {{ ref('bronze_sfdc_campaign_member') }} as s
