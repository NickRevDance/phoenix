{{ config(materialized = 'table') }}

SELECT

      PURCHID
    , ORDERACCOUNT
    , PURCHSTATUS
    , DOCUMENTSTATUS
    , DOCUMENTSTATE
    , CREATEDDATE
    , CURRENCYCODE
    , DLVTERM
    , PAYMENT
    , PORT
    , MCRDROPSHIPMENT
    , INVENTSITEID
    , INVENTLOCATIONID

FROM
    {{ ref('bronze_d365_purch_table') }}
