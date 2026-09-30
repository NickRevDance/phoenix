-- EDW-150 acceptance criteria: exactly one active row per parameter_name (none is as wrong as two: V_DEMAND_PLANNING reads the active row per parameter).
select
      parameter_name
    , sum(case when is_active = 1 then 1 else 0 end) as active_row_count
from {{ ref('ref_demand_planning_thresholds') }}
group by parameter_name
having sum(case when is_active = 1 then 1 else 0 end) <> 1