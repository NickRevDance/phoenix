{{ config(alias = 'sfdc_queue_s_object') }}

select
    s.*
from {{ ref('bronze_sfdc_queue_s_object') }} as s
