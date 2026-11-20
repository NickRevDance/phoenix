{{ config(alias = 'sfdc_group') }}

select
    s.*
from {{ ref('silver_sfdc_group') }} as s
