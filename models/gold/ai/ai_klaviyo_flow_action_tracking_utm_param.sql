{{ config(alias = 'klaviyo_flow_action_tracking_utm_param') }}

select
    s.*
from {{ ref('silver_klaviyo_flow_action_tracking_utm_param') }} as s
