{{ config(alias = 'sfdc_user') }}

select
    s.*
from {{ ref('bronze_sfdc_user') }} as s
