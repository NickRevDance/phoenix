{{ config(alias = 'klaviyo_person') }}

select
    s.*
from {{ ref('silver_klaviyo_person') }} as s
