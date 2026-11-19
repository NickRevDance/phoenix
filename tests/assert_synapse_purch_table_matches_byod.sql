{{ config(severity = 'warn') }}

-- Synapse Link vs BYOD parallel run for PurchTable. Synapse syncs every 6 hours, so POs created in the
-- last day can be missing from it, and a recent change can show as a mismatch until the next sync.
WITH synapse AS (
    SELECT
          pt.purchid
        , pt.orderaccount
        , pt.currencycode
        , CAST(pt.accountingdate AS DATE) AS accountingdate
        , pt.purchstatus
        , pt.documentstatus
        , pt.dlvmode
        , pt.inventlocationid
    FROM {{ ref('bronze_d365_synapse_purch_table') }} pt
    WHERE pt.__END_AT IS NULL
      AND pt.dataareaid <> 'dat'
),

byod AS (
    SELECT
          bp.PURCHID
        , bp.ORDERACCOUNT
        , bp.CURRENCYCODE
        , CAST(bp.ACCOUNTINGDATE AS DATE) AS ACCOUNTINGDATE
        , bp.PURCHSTATUS
        , bp.DOCUMENTSTATUS
        , NULLIF(bp.DLVMODE, '') AS DLVMODE
        , NULLIF(bp.INVENTLOCATIONID, '') AS INVENTLOCATIONID
        , bp.CREATEDDATE
    FROM {{ ref('silver_d365_purch_table') }} bp
)

SELECT
      COALESCE(s.purchid, b.PURCHID) AS purch_id
    , CASE
          WHEN s.purchid IS NULL THEN 'missing_in_synapse'
          WHEN b.PURCHID IS NULL THEN 'missing_in_byod'
          ELSE 'value_mismatch'
      END AS mismatch_type
    , s.orderaccount AS synapse_orderaccount
    , b.ORDERACCOUNT AS byod_orderaccount
    , s.purchstatus AS synapse_purchstatus
    , b.PURCHSTATUS AS byod_purchstatus
    , s.documentstatus AS synapse_documentstatus
    , b.DOCUMENTSTATUS AS byod_documentstatus
FROM synapse s
FULL OUTER JOIN byod b
    ON b.PURCHID = s.purchid
WHERE (s.purchid IS NULL AND b.CREATEDDATE < CURRENT_TIMESTAMP() - INTERVAL 1 DAY)
   OR b.PURCHID IS NULL
   OR (
          s.purchid IS NOT NULL AND b.PURCHID IS NOT NULL
      AND NOT (
              s.orderaccount <=> b.ORDERACCOUNT
          AND s.currencycode <=> b.CURRENCYCODE
          AND s.accountingdate <=> b.ACCOUNTINGDATE
          AND CAST(s.purchstatus AS INT) <=> CAST(b.PURCHSTATUS AS INT)
          AND CAST(s.documentstatus AS INT) <=> CAST(b.DOCUMENTSTATUS AS INT)
          AND s.dlvmode <=> b.DLVMODE
          AND s.inventlocationid <=> b.INVENTLOCATIONID
      )
   )
