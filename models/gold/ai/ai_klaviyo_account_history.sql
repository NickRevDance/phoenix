{{ config(alias = 'klaviyo_account_history') }}

select
    s.*
from {{ ref('silver_klaviyo_account_history') }} as s
