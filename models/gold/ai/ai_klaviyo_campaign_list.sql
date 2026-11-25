{{ config(alias = 'klaviyo_campaign_list') }}

select
    s.*
from {{ ref('silver_klaviyo_campaign_list') }} as s
