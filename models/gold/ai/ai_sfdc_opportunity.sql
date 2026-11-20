{{ config(alias = 'sfdc_opportunity') }}

select
    s.*
from {{ ref('bronze_sfdc_opportunity') }} as s
