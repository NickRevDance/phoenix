-- Every TRADE_AGREEMENT row must key to a real promotion, never the -1 Unknown member.
select

      d.discount_line_key
    , d.promotion_key

from {{ ref('fact_discount_application') }} d

where d.discount_type = 'TRADE_AGREEMENT'
  and d.promotion_key = -1
