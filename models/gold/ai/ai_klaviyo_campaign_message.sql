{{ config(alias = 'klaviyo_campaign_message') }}

select
    s.*
from {{ ref('silver_klaviyo_campaign_message') }} as s
