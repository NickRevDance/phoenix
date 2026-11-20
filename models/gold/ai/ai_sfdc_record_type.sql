{{ config(alias = 'sfdc_record_type') }}

select
    s.*
from {{ ref('silver_sfdc_record_type') }} as s
