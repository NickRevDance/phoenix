{{ config(alias = 'sfdc_account') }}

select
    s.*
from {{ ref('silver_sfdc_account') }} as s
