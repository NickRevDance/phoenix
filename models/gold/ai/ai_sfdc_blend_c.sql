{{ config(alias = 'sfdc_blend_c') }}

select
    s.*
from {{ ref('silver_sfdc_blend_c') }} as s
