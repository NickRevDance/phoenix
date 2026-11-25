{{ config(alias = 'klaviyo_tag_group') }}

select
    s.*
from {{ ref('silver_klaviyo_tag_group') }} as s
