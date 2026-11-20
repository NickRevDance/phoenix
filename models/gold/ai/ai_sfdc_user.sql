{{ config(alias = 'sfdc_user') }}

select
    s.*
from {{ ref('silver_sfdc_user') }} as s
