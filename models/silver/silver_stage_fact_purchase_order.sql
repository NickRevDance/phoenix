{{ config(materialized = 'table') }}

WITH purch_line_raw AS (

    -- Full, unfiltered read of PurchLine -- FACT_PURCHASE_ORDER needs every
    -- line regardless of status, unlike silver_d365_purch_line (filtered to
    -- PURCHSTATUS = 1 for FACT_INVENTORY_SNAPSHOT_DAILY's on_order_qty need).
    -- Reads straight off bronze rather than extending that filtered model,
    -- per the build-order plan's own recommendation.
    SELECT

          PURCHID
        , LINENUMBER
        , ITEMID
        , INVENTDIMID
        , VENDACCOUNT
        , PURCHSTATUS
        , PURCHQTY
        , QTYORDERED
        , REMAINPURCHPHYSICAL
        , REMAININVENTPHYSICAL
        , PURCHRECEIVEDNOW
        , INVENTRECEIVEDNOW
        , PURCHPRICE
        , PURCHUNIT
        , CURRENCYCODE
        , CONFIRMEDDLV
        , DELIVERYDATE
        , REQUESTEDSHIPDATE
        , CONFIRMEDSHIPDATE
        , MCRDROPSHIPMENT
        , PORT
        , MODIFIEDDATE

    FROM {{ ref('bronze_d365_purch_line') }}

),

purch_table AS (

    SELECT

          PURCHID
        , ORDERACCOUNT     as header_vendaccount
        , PURCHSTATUS      as header_purchstatus
        , DOCUMENTSTATUS
        , CREATEDDATE
        , CURRENCYCODE    as header_currencycode
        , DLVTERM
        , PAYMENT
        , PORT            as header_port
        , MCRDROPSHIPMENT as header_mcrdropshipment
        , INVENTSITEID
        , INVENTLOCATIONID

    FROM {{ ref('silver_d365_purch_table') }}

),

inventory_dim AS (

    SELECT

          InventDimID
        , inventsiteid     as dim_inventsiteid
        , INVENTLOCATIONID as dim_inventlocationid
        , INVENTSIZEID
        , INVENTCOLORID

    FROM {{ ref('silver_d365_inventory_dim') }}

),

joined AS (

    SELECT

          l.*
        , t.header_vendaccount
        , t.header_purchstatus
        , t.DOCUMENTSTATUS
        , t.CREATEDDATE
        , t.header_currencycode
        , t.DLVTERM
        , t.PAYMENT
        , t.header_port
        , t.header_mcrdropshipment
        , t.INVENTSITEID
        , t.INVENTLOCATIONID

        , d.dim_inventsiteid
        , d.dim_inventlocationid
        , d.INVENTSIZEID
        , d.INVENTCOLORID

    FROM purch_line_raw l
    LEFT JOIN purch_table t
        ON l.PURCHID = t.PURCHID
    LEFT JOIN inventory_dim d
        ON l.INVENTDIMID = d.InventDimID

)

SELECT
      j.*
    -- Business key exactly as the spec's own Key Structure section states it
    -- (purchase_order_id + purchase_order_line_number + source_system). No
    -- RECID exists on this BYOD export (unlike SalesLine/InventTrans), and
    -- PURCHID+LINENUMBER is already 100% unique live (55,750 of 55,750 rows,
    -- confirmed 2026-09-14) -- no separate surrogate business key needed.
    , md5(concat_ws('|', j.PURCHID, cast(j.LINENUMBER as string), 'D365')) as purchase_order_entity_key

    -- Change hash: what triggers a new version row. Includes the raw
    -- receipt-progress fields (REMAINPURCHPHYSICAL/PURCHRECEIVEDNOW/
    -- INVENTRECEIVEDNOW) even though the clean received_qty/open_qty gold
    -- columns stay null-with-note for now -- so once the receipt-qty source
    -- question is resolved, this snapshot already has the version history
    -- captured rather than only starting from that point forward.
    -- NEEDS CONFIRMATION with Nick: which of PURCHRECEIVEDNOW vs
    -- INVENTRECEIVEDNOW vs REMAINPURCHPHYSICAL is the authoritative
    -- received-quantity field.
    , sha2(
        concat_ws('||',
            cast(j.PURCHSTATUS as string),
            coalesce(cast(j.header_purchstatus as string), ''),
            coalesce(cast(j.PURCHPRICE as string), ''),
            coalesce(j.CURRENCYCODE, ''),
            coalesce(cast(j.CONFIRMEDDLV as string), ''),
            coalesce(cast(j.REQUESTEDSHIPDATE as string), ''),
            coalesce(cast(j.CONFIRMEDSHIPDATE as string), ''),
            coalesce(cast(j.REMAINPURCHPHYSICAL as string), ''),
            coalesce(cast(j.PURCHRECEIVEDNOW as string), ''),
            coalesce(cast(j.INVENTRECEIVEDNOW as string), ''),
            coalesce(j.VENDACCOUNT, '')
        ), 256
      ) as po_change_hash
FROM joined j
