{{ config(alias = 'klaviyo_metric') }}

select
    s.*
from {{ ref('silver_klaviyo_metric') }} as s
