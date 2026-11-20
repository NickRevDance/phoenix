{{ config(alias = 'sfdc_opportunity') }}

select
    s.*
from {{ ref('silver_sfdc_opportunity') }} as s
