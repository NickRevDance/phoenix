{{ config(alias = 'klaviyo_flow_action') }}

select
    s.*
from {{ ref('silver_klaviyo_flow_action') }} as s
