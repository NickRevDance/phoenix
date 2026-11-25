{{ config(alias = 'klaviyo_segment_person') }}

select
    s.*
from {{ ref('silver_klaviyo_segment_person') }} as s
