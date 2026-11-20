{{ config(alias = 'sfdc_email_message_relation') }}

select
    s.*
from {{ ref('silver_sfdc_email_message_relation') }} as s
