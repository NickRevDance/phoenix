{{ config(materialized = 'table') }}

SELECT

      PURCHID
    , ORDERACCOUNT
    , PURCHSTATUS
    , DOCUMENTSTATUS
    , WORKFLOWSTATE
    , CREATEDDATE
    , CURRENCYCODE
    , DLVTERM
    , PAYMENT
    , PORT
    , MCRDROPSHIPMENT
    , INVENTSITEID
    , INVENTLOCATIONID
    , MODIFIEDDATE

FROM
    {{ ref('bronze_d365_purch_table') }}
