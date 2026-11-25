{{ config(alias = 'klaviyo_event') }}

select
    s.*
from {{ ref('silver_klaviyo_event') }} as s
