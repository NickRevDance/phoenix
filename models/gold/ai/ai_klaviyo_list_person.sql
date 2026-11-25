{{ config(alias = 'klaviyo_list_person') }}

select
    s.*
from {{ ref('silver_klaviyo_list_person') }} as s
