-- ============================================================
-- ECOVEX INVENTORY — migration v10
-- Run in Supabase SQL editor after v9.
--
-- Adds a Returns feature: employees (leaving, or just returning
-- extra/unused items) can hand items back. Usable returns go back
-- into stock automatically. Not-usable returns are recorded but
-- don't add back to stock — they're effectively a damage/wastage
-- record.
-- ============================================================

create table if not exists returns_log (
  id uuid primary key default gen_random_uuid(),
  return_date date not null default current_date,
  attendant_id uuid not null references attendants(id),
  category text not null check (category in ('Material', 'Solution')),
  material_id uuid references materials(id),
  solution_id uuid references solutions(id),
  qty_returned numeric not null check (qty_returned > 0),
  condition text not null check (condition in ('Usable', 'Not Usable')),
  remarks text,
  returned_to text, -- who received/checked the return
  created_at timestamptz not null default now(),
  check (
    (category = 'Material' and material_id is not null and solution_id is null) or
    (category = 'Solution' and solution_id is not null and material_id is null)
  )
);

alter table returns_log enable row level security;
drop policy if exists "Public read/write - returns_log" on returns_log;
create policy "Public read/write - returns_log" on returns_log for all using (true) with check (true);

-- ---------- Stock views: usable returns add back to available stock ----------

drop view if exists stock_materials;
create view stock_materials as
select
  m.id,
  m.name as material_name,
  m.unit,
  coalesce((select sum(mp.quantity) from materials_purchases mp where mp.material_id = m.id), 0) as total_purchased,
  coalesce((select sum(il.qty_issued) from issuance_log il where il.material_id = m.id and il.category = 'Material'), 0) as total_issued,
  coalesce((select sum(rl.qty_returned) from returns_log rl where rl.material_id = m.id and rl.category = 'Material' and rl.condition = 'Usable'), 0) as total_returned_usable,
  coalesce((select sum(mp.quantity) from materials_purchases mp where mp.material_id = m.id), 0)
    - coalesce((select sum(il.qty_issued) from issuance_log il where il.material_id = m.id and il.category = 'Material'), 0)
    + coalesce((select sum(rl.qty_returned) from returns_log rl where rl.material_id = m.id and rl.category = 'Material' and rl.condition = 'Usable'), 0) as available_stock,
  m.reorder_level,
  case when
    coalesce((select sum(mp.quantity) from materials_purchases mp where mp.material_id = m.id), 0)
    - coalesce((select sum(il.qty_issued) from issuance_log il where il.material_id = m.id and il.category = 'Material'), 0)
    + coalesce((select sum(rl.qty_returned) from returns_log rl where rl.material_id = m.id and rl.category = 'Material' and rl.condition = 'Usable'), 0)
    <= m.reorder_level
  then 'Reorder' else 'OK' end as status
from materials m
order by m.name;

drop view if exists stock_solutions;
create view stock_solutions as
select
  s.id,
  s.name as solution_name,
  s.bottle_size_ml,
  coalesce((select sum(sl.litres) from solutions_log sl where sl.solution_id = s.id), 0) as total_in_l,
  coalesce((select sum(il.litres_issued) from issuance_log il where il.solution_id = s.id and il.category = 'Solution'), 0) as total_issued_l,
  coalesce((select sum(rl.qty_returned) from returns_log rl where rl.solution_id = s.id and rl.category = 'Solution' and rl.condition = 'Usable'), 0) as total_returned_usable_l,
  coalesce((select sum(sl.litres) from solutions_log sl where sl.solution_id = s.id), 0)
    - coalesce((select sum(il.litres_issued) from issuance_log il where il.solution_id = s.id and il.category = 'Solution'), 0)
    + coalesce((select sum(rl.qty_returned) from returns_log rl where rl.solution_id = s.id and rl.category = 'Solution' and rl.condition = 'Usable'), 0) as available_l,
  round(
    (coalesce((select sum(sl.litres) from solutions_log sl where sl.solution_id = s.id), 0)
    - coalesce((select sum(il.litres_issued) from issuance_log il where il.solution_id = s.id and il.category = 'Solution'), 0)
    + coalesce((select sum(rl.qty_returned) from returns_log rl where rl.solution_id = s.id and rl.category = 'Solution' and rl.condition = 'Usable'), 0))
    / (s.bottle_size_ml / 1000.0), 2
  ) as available_bottles,
  s.reorder_level_l,
  case when
    (coalesce((select sum(sl.litres) from solutions_log sl where sl.solution_id = s.id), 0)
    - coalesce((select sum(il.litres_issued) from issuance_log il where il.solution_id = s.id and il.category = 'Solution'), 0)
    + coalesce((select sum(rl.qty_returned) from returns_log rl where rl.solution_id = s.id and rl.category = 'Solution' and rl.condition = 'Usable'), 0))
    <= s.reorder_level_l
  then 'Reorder' else 'OK' end as status
from solutions s
order by s.name;

-- ---------- What does each employee currently have outstanding? ----------
-- (issued minus returned of ANY condition — once it's returned, it's no
-- longer "with" them, whether or not it went back into usable stock)

create or replace view employee_outstanding_materials as
select
  il.attendant_id,
  il.material_id,
  m.name as material_name,
  m.unit,
  coalesce(sum(il.qty_issued), 0) - coalesce((
    select sum(rl.qty_returned) from returns_log rl
    where rl.attendant_id = il.attendant_id and rl.material_id = il.material_id and rl.category = 'Material'
  ), 0) as qty_outstanding
from issuance_log il
join materials m on m.id = il.material_id
where il.category = 'Material'
group by il.attendant_id, il.material_id, m.name, m.unit;

create or replace view employee_outstanding_solutions as
select
  il.attendant_id,
  il.solution_id,
  s.name as solution_name,
  s.bottle_size_ml,
  coalesce(sum(il.litres_issued), 0) - coalesce((
    select sum(rl.qty_returned) from returns_log rl
    where rl.attendant_id = il.attendant_id and rl.solution_id = il.solution_id and rl.category = 'Solution'
  ), 0) as litres_outstanding
from issuance_log il
join solutions s on s.id = il.solution_id
where il.category = 'Solution'
group by il.attendant_id, il.solution_id, s.name, s.bottle_size_ml;

-- ---------- Returns history, for the History page and auditing ----------

create or replace view returns_history as
select
  rl.id,
  rl.return_date,
  a.name as attendant_name,
  a.code as attendant_code,
  rl.category,
  coalesce(m.name, s.name) as item_name,
  rl.qty_returned,
  rl.condition,
  rl.returned_to,
  rl.remarks,
  rl.created_at
from returns_log rl
join attendants a on a.id = rl.attendant_id
left join materials m on m.id = rl.material_id
left join solutions s on s.id = rl.solution_id
order by rl.return_date desc, rl.created_at desc;
