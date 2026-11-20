{{ config(alias = 'sfdc_blend_c') }}

select
    s.*
from {{ ref('bronze_sfdc_blend_c') }} as s
