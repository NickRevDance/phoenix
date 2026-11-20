{{ config(alias = 'sfdc_record_type') }}

select
    s.*
from {{ ref('bronze_sfdc_record_type') }} as s
