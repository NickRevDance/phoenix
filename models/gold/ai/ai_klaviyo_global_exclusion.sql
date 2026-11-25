{{ config(alias = 'klaviyo_global_exclusion') }}

select
    s.*
from {{ ref('silver_klaviyo_global_exclusion') }} as s
