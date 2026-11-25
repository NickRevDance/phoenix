{{ config(alias = 'klaviyo_segment') }}

select
    s.*
from {{ ref('silver_klaviyo_segment') }} as s
