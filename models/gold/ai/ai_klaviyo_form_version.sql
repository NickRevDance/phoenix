{{ config(alias = 'klaviyo_form_version') }}

select
    s.*
from {{ ref('silver_klaviyo_form_version') }} as s
