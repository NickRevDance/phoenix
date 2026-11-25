{{ config(alias = 'klaviyo_campaign_message_send_time') }}

select
    s.*
from {{ ref('silver_klaviyo_campaign_message_send_time') }} as s
