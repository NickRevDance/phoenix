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

-- Added 2026-09-17 for EDW's PO receipt/invoice gap -- Rev_VendPackingSlipTransStaging
-- and Rev_VendInvoiceTransStaging landed in BYOD this session. Aggregated to
-- PURCHID+LINENUMBER (the PO line grain) before joining -- both source tables
-- carry multiple rows per line (partial receipts / multiple invoices).
vend_packing_slip AS (

    -- silver_d365_vend_packing_slip_trans already renames ORIGPURCHID -> PURCHID
    SELECT

          PURCHID
        , PURCHASELINELINENUMBER as LINENUMBER
        , sum(QTY)          as ps_received_qty
        , sum(CANCELLEDQTY) as ps_cancelled_qty
        , min(INVENTDATE)   as first_receipt_date
        , max(INVENTDATE)   as last_receipt_date

    FROM {{ ref('silver_d365_vend_packing_slip_trans') }}
    GROUP BY PURCHID, PURCHASELINELINENUMBER

),

vend_invoice AS (

    SELECT

          PURCHID
        , PURCHASELINELINENUMBER as LINENUMBER
        , sum(QTY) as invoiced_qty

    FROM {{ ref('silver_d365_vend_invoice_trans') }}
    WHERE PURCHASELINELINENUMBER != 0  -- 0 = non-line-specific charge (freight/misc), not a PO line
    GROUP BY PURCHID, PURCHASELINELINENUMBER

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

        -- Receipt qty: packing-slip ground truth where it exists; else the
        -- PURCHQTY - REMAINPURCHPHYSICAL formula, validated live 2026-09-17
        -- against the packing-slip data for statuses 1/2/3 (Backorder/
        -- Received/Invoiced) -- 2194/2195 exact matches. NOT applied for
        -- status 4 (Canceled): REMAINPURCHPHYSICAL=0 there doesn't reliably
        -- mean "fully received" (can mean "remainder was cancelled, not
        -- received") -- confirmed wrong in the one ground-truth Canceled
        -- case available. Left null rather than guessed for Canceled lines
        -- with no packing-slip row.
        , coalesce(
            vps.ps_received_qty,
            case when l.PURCHSTATUS in (1,2,3)
                 then l.PURCHQTY - l.REMAINPURCHPHYSICAL
                 else cast(null as decimal(18,4))
            end
          ) as received_qty
        , vps.ps_cancelled_qty as cancelled_qty  -- packing-slip only, no formula fallback exists
        , vps.first_receipt_date
        , vps.last_receipt_date
        , vi.invoiced_qty

    FROM purch_line_raw l
    LEFT JOIN purch_table t
        ON l.PURCHID = t.PURCHID
    LEFT JOIN inventory_dim d
        ON l.INVENTDIMID = d.InventDimID
    LEFT JOIN vend_packing_slip vps
        ON l.PURCHID = vps.PURCHID AND cast(l.LINENUMBER as bigint) = cast(vps.LINENUMBER as bigint)
    LEFT JOIN vend_invoice vi
        ON l.PURCHID = vi.PURCHID AND cast(l.LINENUMBER as bigint) = cast(vi.LINENUMBER as bigint)

)

SELECT
      j.*
    -- Business key exactly as the spec's own Key Structure section states it
    -- (purchase_order_id + purchase_order_line_number + source_system). No
    -- RECID exists on this BYOD export (unlike SalesLine/InventTrans), and
    -- PURCHID+LINENUMBER is already 100% unique live (confirmed 2026-09-14)
    -- -- no separate surrogate business key needed.
    , md5(concat_ws('|', j.PURCHID, cast(j.LINENUMBER as string), 'D365')) as purchase_order_entity_key

    -- Change hash: what triggers a new version row. Includes receipt/invoice
    -- progress (received_qty/cancelled_qty/invoiced_qty/last_receipt_date,
    -- added 2026-09-17) alongside the original status/price/date/vendor set,
    -- so a new receipt or invoice posting now creates a new snapshot version.
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
            coalesce(j.VENDACCOUNT, ''),
            coalesce(cast(j.received_qty as string), ''),
            coalesce(cast(j.cancelled_qty as string), ''),
            coalesce(cast(j.invoiced_qty as string), ''),
            coalesce(cast(j.last_receipt_date as string), '')
        ), 256
      ) as po_change_hash
FROM joined j
