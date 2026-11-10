{{ config(severity = 'warn') }}

-- A line can sync a run ahead of its header, so this warns rather than fails.
SELECT
      pst.SALESID
    , pst.PACKINGSLIPID
    , COUNT(*) AS line_count
FROM {{ ref('silver_d365_cust_packing_slip_trans') }} pst
LEFT JOIN {{ ref('silver_d365_cust_packing_slip_jour') }} psj
    ON psj.SALESID = pst.SALESID
   AND psj.PACKINGSLIPID = pst.PACKINGSLIPID
WHERE psj.RECID IS NULL
GROUP BY pst.SALESID, pst.PACKINGSLIPID
