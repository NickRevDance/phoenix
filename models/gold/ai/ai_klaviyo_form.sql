{{ config(alias = 'klaviyo_form') }}

select
    s.*
from {{ ref('silver_klaviyo_form') }} as s
