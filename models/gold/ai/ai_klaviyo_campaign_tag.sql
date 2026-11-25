{{ config(alias = 'klaviyo_campaign_tag') }}

select
    s.*
from {{ ref('silver_klaviyo_campaign_tag') }} as s
