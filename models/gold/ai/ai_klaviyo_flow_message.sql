{{ config(alias = 'klaviyo_flow_message') }}

select
    s.*
from {{ ref('silver_klaviyo_flow_message') }} as s
