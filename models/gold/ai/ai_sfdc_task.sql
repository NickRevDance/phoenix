{{ config(alias = 'sfdc_task') }}

select
    s.*
from {{ ref('bronze_sfdc_task') }} as s
