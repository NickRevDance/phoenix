{{ config(alias = 'klaviyo_list') }}

select
    s.*
from {{ ref('silver_klaviyo_list') }} as s
