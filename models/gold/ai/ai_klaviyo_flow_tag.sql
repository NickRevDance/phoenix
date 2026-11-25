{{ config(alias = 'klaviyo_flow_tag') }}

select
    s.*
from {{ ref('silver_klaviyo_flow_tag') }} as s
