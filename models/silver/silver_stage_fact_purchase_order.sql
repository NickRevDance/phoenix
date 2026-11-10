{{ config(materialized = 'table') }}

-- FACT_PURCHASE_ORDER v1.0 stage: one row per PO line, every status and both order classes.
-- Receipts, invoices and in-transit rows join on INVENTTRANSID (spec 4.2); D365 dates at or before 1901-01-01 are NULL (spec 8.4).

WITH purch_line AS (

    -- Unfiltered bronze: silver_d365_purch_line is filtered to Backorder for the inventory snapshot (spec 8.1).
    SELECT

          l.PURCHID
        , l.LINENUMBER
        , l.INVENTTRANSID
        , l.INVENTDIMID
        , l.ITEMID
        , l.BARCODE
        , l.NAME
        , l.VENDACCOUNT
        , l.PURCHSTATUS
        , l.PURCHQTY
        , l.REMAINPURCHPHYSICAL
        , l.PURCHUNIT
        , l.PURCHPRICE
        , l.CURRENCYCODE
        , case when cast(l.DELIVERYDATE as date) > date'1901-01-01' then cast(l.DELIVERYDATE as date) end           AS DELIVERYDATE
        , case when cast(l.CONFIRMEDDLV as date) > date'1901-01-01' then cast(l.CONFIRMEDDLV as date) end           AS CONFIRMEDDLV
        , case when cast(l.ITMEXFACTORYDATE as date) > date'1901-01-01' then cast(l.ITMEXFACTORYDATE as date) end   AS ITMEXFACTORYDATE
        , case when cast(l.ITMINTOSTOREDATE as date) > date'1901-01-01' then cast(l.ITMINTOSTOREDATE as date) end   AS ITMINTOSTOREDATE
        , nullif(l.ITMSTATUSID, '')                                                                                 AS ITMSTATUSID
        , nullif(l.DLVMODE, '')                                                                                     AS DLVMODE
        , l.MCRDROPSHIPMENT
        , l.STOCKEDPRODUCT

    FROM {{ ref('bronze_d365_purch_line') }} l

),

purch_table AS (

    SELECT

          t.PURCHID
        , t.ORDERACCOUNT
        , t.PURCHSTATUS
        , t.DOCUMENTSTATUS
        , t.DOCUMENTSTATE
        , t.CREATEDDATE
        , case when cast(t.ACCOUNTINGDATE as date) > date'1901-01-01' then cast(t.ACCOUNTINGDATE as date) end      AS ACCOUNTINGDATE
        , nullif(t.VENDGROUP, '')                                                                                   AS VENDGROUP
        , nullif(t.REVREASON, '')                                                                                   AS REVREASON
        , nullif(t.REVMANUFACTURINGSTATUS, '')                                                                      AS REVMANUFACTURINGSTATUS
        , nullif(t.PAYMENT, '')                                                                                     AS PAYMENT
        , nullif(t.DLVMODE, '')                                                                                     AS DLVMODE
        , nullif(t.INVENTSITEID, '')                                                                                AS INVENTSITEID
        , nullif(t.INVENTLOCATIONID, '')                                                                            AS INVENTLOCATIONID

    FROM {{ ref('silver_d365_purch_table') }} t

),

inventory_dim AS (

    SELECT

          d.InventDimID
        , nullif(d.inventsiteid, '')      AS INVENTSITEID
        , nullif(d.INVENTLOCATIONID, '')  AS INVENTLOCATIONID
        , d.INVENTSIZEID
        , d.INVENTCOLORID

    FROM {{ ref('silver_d365_inventory_dim') }} d

),

goods_in_transit AS (

    -- One row per PO line (INVENTTRANSIDREF unique); STATUS 1 in transit, 2 received.
    SELECT

          g.INVENTTRANSIDREF
        , g.GITID
        , g.STATUS
        , g.QTY
        , g.REMAINQTY
        , case when cast(g.GITDATE as date) > date'1901-01-01' then cast(g.GITDATE as date) end           AS GITDATE
        , case when cast(g.EXPECTEDDATE as date) > date'1901-01-01' then cast(g.EXPECTEDDATE as date) end AS EXPECTEDDATE

    FROM {{ ref('silver_d365_itm_goods_in_transit_order') }} g

),

packing_slip AS (

    SELECT

          ps.INVENTTRANSID
        , sum(ps.QTY)           AS ps_qty
        , sum(ps.CANCELLEDQTY)  AS ps_cancelled_qty
        , min(case when cast(ps.INVENTDATE as date) > date'1901-01-01' then cast(ps.INVENTDATE as date) end) AS ps_first_date
        , max(case when cast(ps.INVENTDATE as date) > date'1901-01-01' then cast(ps.INVENTDATE as date) end) AS ps_last_date

    FROM {{ ref('silver_d365_vend_packing_slip_trans') }} ps
    GROUP BY ps.INVENTTRANSID

),

invoice AS (

    SELECT

          vi.INVENTTRANSID
        , sum(vi.QTY) AS inv_qty

    FROM {{ ref('silver_d365_vend_invoice_trans') }} vi
    WHERE vi.PURCHASELINELINENUMBER <> 0  -- header-level charges, not PO lines
    GROUP BY vi.INVENTTRANSID

),

joined AS (

    SELECT

          l.*
        , CASE WHEN l.PURCHID LIKE 'O/UPO-%' THEN 'ADJUSTMENT' ELSE 'VENDOR' END     AS purchase_order_class
        , CASE WHEN l.PURCHID LIKE 'O/UPO-%' THEN 'O/UPO'
               ELSE regexp_extract(l.PURCHID, '^([A-Za-z/]+-[0-9]{2})', 1) END        AS po_series_code
        , t.ORDERACCOUNT
        , t.PURCHSTATUS                                                               AS header_purchstatus
        , t.DOCUMENTSTATUS
        , t.DOCUMENTSTATE
        , t.CREATEDDATE
        , t.ACCOUNTINGDATE
        , t.VENDGROUP
        , t.REVREASON
        , t.REVMANUFACTURINGSTATUS
        , t.PAYMENT
        , t.DLVMODE                                                                   AS header_dlvmode
        , coalesce(d.INVENTLOCATIONID, t.INVENTLOCATIONID)                           AS warehouse_id
        , CASE WHEN d.INVENTLOCATIONID IS NOT NULL THEN d.INVENTSITEID ELSE t.INVENTSITEID END AS inventory_site_id
        , d.INVENTSIZEID
        , d.INVENTCOLORID
        , g.GITID                                                                     AS goods_in_transit_id
        , g.STATUS                                                                    AS goods_in_transit_status
        , g.GITDATE                                                                   AS shipped_date
        , g.EXPECTEDDATE                                                              AS expected_arrival_date
        , g.QTY                                                                       AS git_qty
        , g.REMAINQTY                                                                 AS git_remain_qty
        , ps.INVENTTRANSID IS NOT NULL                                                AS has_packing_slip
        , ps.ps_qty
        , ps.ps_cancelled_qty
        , ps.ps_first_date
        , ps.ps_last_date
        , cast(coalesce(vi.inv_qty, 0) AS decimal(18,4))                              AS invoiced_qty

    FROM purch_line l
    LEFT JOIN purch_table t
        ON l.PURCHID = t.PURCHID
    LEFT JOIN inventory_dim d
        ON l.INVENTDIMID = d.InventDimID
    LEFT JOIN goods_in_transit g
        ON l.INVENTTRANSID = g.INVENTTRANSIDREF
    LEFT JOIN packing_slip ps
        ON l.INVENTTRANSID = ps.INVENTTRANSID
    LEFT JOIN invoice vi
        ON l.INVENTTRANSID = vi.INVENTTRANSID

),

quantities AS (

    -- Spec 4.1 / 8.3: VENDOR receipts come from the in-transit row, ADJUSTMENT receipts from the packing slip.
    SELECT

          j.*
        , cast(CASE
            WHEN j.purchase_order_class = 'ADJUSTMENT' THEN 0
            ELSE coalesce(j.git_remain_qty, 0)
          END AS decimal(18,4))                                                       AS in_transit_qty
        , cast(CASE
            WHEN j.purchase_order_class = 'ADJUSTMENT' THEN coalesce(j.ps_qty, 0)
            WHEN j.goods_in_transit_id IS NOT NULL THEN j.git_qty - j.git_remain_qty
            WHEN j.PURCHSTATUS = 3 THEN j.PURCHQTY - j.REMAINPURCHPHYSICAL       -- Invoiced with no in-transit row; raised as a DQ exception
            ELSE 0
          END AS decimal(18,4))                                                       AS received_qty
        , cast(CASE
            WHEN j.purchase_order_class = 'ADJUSTMENT' AND j.has_packing_slip THEN j.ps_cancelled_qty
            WHEN j.PURCHSTATUS = 4 THEN j.PURCHQTY - j.invoiced_qty
            ELSE 0
          END AS decimal(18,4))                                                       AS cancelled_qty
        , CASE
            WHEN j.purchase_order_class = 'ADJUSTMENT' THEN j.ps_first_date
            WHEN j.goods_in_transit_status = 2 THEN j.ITMINTOSTOREDATE
          END                                                                         AS first_receipt_date
        , CASE
            WHEN j.purchase_order_class = 'ADJUSTMENT' THEN j.ps_last_date
            WHEN j.goods_in_transit_status = 2 THEN j.ITMINTOSTOREDATE
          END                                                                         AS last_receipt_date

    FROM joined j

)

SELECT

      q.*
    , md5(concat_ws('|', q.PURCHID, cast(q.LINENUMBER AS string), 'D365'))             AS purchase_order_entity_key
    , {{ generate_row_hash([
          "coalesce(cast(q.PURCHSTATUS as string), '')",
          "coalesce(cast(q.header_purchstatus as string), '')",
          "coalesce(cast(q.PURCHQTY as string), '')",
          "coalesce(cast(q.PURCHPRICE as string), '')",
          "coalesce(q.CURRENCYCODE, '')",
          "coalesce(cast(q.DELIVERYDATE as string), '')",
          "coalesce(cast(q.CONFIRMEDDLV as string), '')",
          "coalesce(cast(q.REMAINPURCHPHYSICAL as string), '')",
          "coalesce(cast(q.received_qty as string), '')",
          "coalesce(cast(q.cancelled_qty as string), '')",
          "coalesce(cast(q.invoiced_qty as string), '')",
          "coalesce(cast(q.in_transit_qty as string), '')",
          "coalesce(cast(q.last_receipt_date as string), '')",
          "coalesce(q.VENDACCOUNT, '')",
          "coalesce(q.REVMANUFACTURINGSTATUS, '')",
          "coalesce(q.ITMSTATUSID, '')"
      ]) }}                                                                             AS po_change_hash

FROM quantities q
