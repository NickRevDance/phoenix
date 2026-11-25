{{ config(alias = 'klaviyo_flow') }}

select
    s.*
from {{ ref('silver_klaviyo_flow') }} as s
