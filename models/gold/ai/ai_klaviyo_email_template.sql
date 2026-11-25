{{ config(alias = 'klaviyo_email_template') }}

select
    s.*
from {{ ref('silver_klaviyo_email_template') }} as s
