{{ config(alias = 'klaviyo_campaign') }}

select
    s.*
from {{ ref('silver_klaviyo_campaign') }} as s
