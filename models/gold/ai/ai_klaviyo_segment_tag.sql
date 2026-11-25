{{ config(alias = 'klaviyo_segment_tag') }}

select
    s.*
from {{ ref('silver_klaviyo_segment_tag') }} as s
