{{ config(alias = 'sfdc_queue_s_object') }}

select
    s.*
from {{ ref('silver_sfdc_queue_s_object') }} as s
