{{ config(alias = 'sfdc_campaign_member') }}

select
    s.*
from {{ ref('silver_sfdc_campaign_member') }} as s
