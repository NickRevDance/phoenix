{{ config(alias = 'sfdc_case') }}

select
    s.*
from {{ ref('silver_sfdc_case') }} as s
