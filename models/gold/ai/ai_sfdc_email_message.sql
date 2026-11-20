{{ config(alias = 'sfdc_email_message') }}

select
    s.*
from {{ ref('silver_sfdc_email_message') }} as s
