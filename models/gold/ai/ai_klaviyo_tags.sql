{{ config(alias = 'klaviyo_tags') }}

select
    s.*
from {{ ref('silver_klaviyo_tags') }} as s
