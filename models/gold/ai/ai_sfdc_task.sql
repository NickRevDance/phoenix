{{ config(alias = 'sfdc_task') }}

select
    s.*
from {{ ref('silver_sfdc_task') }} as s
