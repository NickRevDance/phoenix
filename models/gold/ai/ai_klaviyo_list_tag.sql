{{ config(alias = 'klaviyo_list_tag') }}

select
    s.*
from {{ ref('silver_klaviyo_list_tag') }} as s
