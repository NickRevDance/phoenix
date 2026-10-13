-- S1 monitor: share of discount dollars on promotion_key = -1. Warn only, never a gate.
{{ config(severity = 'warn') }}

select

      sum(case when d.promotion_key = -1 then abs(d.discount_amount) else 0 end) / nullif(sum(abs(d.discount_amount)), 0) as unknown_discount_share

from {{ ref('fact_discount_application') }} d

having sum(case when d.promotion_key = -1 then abs(d.discount_amount) else 0 end) / nullif(sum(abs(d.discount_amount)), 0) > {{ var('discount_unknown_promotion_warn_share', 0.7) }}
