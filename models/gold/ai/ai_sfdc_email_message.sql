{{ config(alias = 'sfdc_email_message') }}

select
    s.*
from {{ ref('bronze_sfdc_email_message') }} as s
