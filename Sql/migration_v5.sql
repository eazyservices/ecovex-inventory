-- ============================================================
-- ECOVEX INVENTORY — migration v5 (fixed)
-- Run in Supabase SQL editor after v2, v3, v4.
-- If you already tried the old version and got a "cannot change
-- name of view column" error, this version fixes that — it drops
-- the view first instead of trying to replace it in place.
-- ============================================================

drop view if exists stock_solutions;

create view stock_solutions as
select
  s.id,
  s.name as solution_name,
  s.bottle_size_ml,
  coalesce((select sum(sl.litres) from solutions_log sl where sl.solution_id = s.id), 0) as total_in_l,
  coalesce((select sum(il.litres_issued) from issuance_log il where il.solution_id = s.id and il.category = 'Solution'), 0) as total_issued_l,
  coalesce((select sum(sl.litres) from solutions_log sl where sl.solution_id = s.id), 0)
    - coalesce((select sum(il.litres_issued) from issuance_log il where il.solution_id = s.id and il.category = 'Solution'), 0) as available_l,
  round(
    (coalesce((select sum(sl.litres) from solutions_log sl where sl.solution_id = s.id), 0)
    - coalesce((select sum(il.litres_issued) from issuance_log il where il.solution_id = s.id and il.category = 'Solution'), 0))
    / (s.bottle_size_ml / 1000.0), 2
  ) as available_bottles,
  s.reorder_level_l,
  case when
    coalesce((select sum(sl.litres) from solutions_log sl where sl.solution_id = s.id), 0)
    - coalesce((select sum(il.litres_issued) from issuance_log il where il.solution_id = s.id and il.category = 'Solution'), 0)
    <= s.reorder_level_l
  then 'Reorder' else 'OK' end as status
from solutions s
order by s.name;
