{{ config(alias = 'sfdc_group') }}

select
    s.*
from {{ ref('bronze_sfdc_group') }} as s
