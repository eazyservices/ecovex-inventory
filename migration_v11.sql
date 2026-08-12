-- ============================================================
-- ECOVEX INVENTORY — migration v11
-- Run in Supabase SQL editor after v10.
--
-- 1. Materials and Solutions now get a "current cost" concept —
--    the same pattern Chemicals already had (migration v8):
--    auto-updates to the latest real Purchase price, editable
--    directly any time, used for all forward-looking costing.
--    Your full purchase history (every price, every vendor, every
--    date) is untouched — this only changes what number is used
--    to answer "what does this cost right now."
-- 2. Stock page now shows per-unit cost for Materials too.
-- 3. Kit Templates now show a total cost per kit, computed live
--    from current prices — "how much does a New Employee Kit
--    actually cost us" / "how much is a Monthly Refill."
-- ============================================================

-- ---------- 1. Materials: current cost per unit ----------

alter table materials add column if not exists current_unit_cost numeric not null default 0;

update materials m
set current_unit_cost = coalesce((
  select round(sum(mp.total_landed_cost) / sum(mp.quantity), 4)
  from materials_purchases mp
  where mp.material_id = m.id and mp.quantity > 0
), 0)
where m.current_unit_cost = 0;

create or replace function fn_update_material_price_on_purchase()
returns trigger language plpgsql as $$
begin
  if new.entry_type = 'Purchase' and new.unit_cost > 0 then
    update materials set current_unit_cost = new.unit_cost where id = new.material_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_update_material_price on materials_purchases;
create trigger trg_update_material_price
  after insert on materials_purchases
  for each row execute function fn_update_material_price_on_purchase();

-- ---------- 2. Solutions: current cost per litre ----------
-- Any log type counts here (Purchased, Prepared, Opening Stock with a
-- known cost) since each represents a real cost for that litre right now.

alter table solutions add column if not exists current_cost_per_litre numeric not null default 0;

update solutions s
set current_cost_per_litre = coalesce((
  select round(sum(sl.total_landed_cost) / sum(sl.litres), 4)
  from solutions_log sl
  where sl.solution_id = s.id and sl.litres > 0
), 0)
where s.current_cost_per_litre = 0;

create or replace function fn_update_solution_price_on_log()
returns trigger language plpgsql as $$
begin
  if new.litres > 0 and new.total_landed_cost > 0 then
    update solutions set current_cost_per_litre = round(new.total_landed_cost / new.litres, 4) where id = new.solution_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_update_solution_price on solutions_log;
create trigger trg_update_solution_price
  after insert on solutions_log
  for each row execute function fn_update_solution_price_on_log();

-- ---------- 3. Stock views now expose current cost ----------

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
  m.current_unit_cost,
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
  s.current_cost_per_litre,
  s.reorder_level_l,
  case when
    (coalesce((select sum(sl.litres) from solutions_log sl where sl.solution_id = s.id), 0)
    - coalesce((select sum(il.litres_issued) from issuance_log il where il.solution_id = s.id and il.category = 'Solution'), 0)
    + coalesce((select sum(rl.qty_returned) from returns_log rl where rl.solution_id = s.id and rl.category = 'Solution' and rl.condition = 'Usable'), 0))
    <= s.reorder_level_l
  then 'Reorder' else 'OK' end as status
from solutions s
order by s.name;

-- ---------- 4. Kit Templates: total cost per kit, live ----------

create or replace view kit_template_item_costs as
select
  kti.id,
  kti.template_id,
  kti.category,
  kti.material_id,
  kti.solution_id,
  kti.qty,
  case when kti.category = 'Material' then coalesce(sm.current_unit_cost, 0) else coalesce(ss.current_cost_per_litre, 0) end as unit_cost,
  kti.qty * case when kti.category = 'Material' then coalesce(sm.current_unit_cost, 0) else coalesce(ss.current_cost_per_litre, 0) end as line_cost
from kit_template_items kti
left join stock_materials sm on sm.id = kti.material_id
left join stock_solutions ss on ss.id = kti.solution_id;

create or replace view kit_template_costs as
select
  kt.id as template_id,
  kt.name as template_name,
  coalesce(sum(ktic.line_cost), 0) as total_cost
from kit_templates kt
left join kit_template_item_costs ktic on ktic.template_id = kt.id
group by kt.id, kt.name;

-- ---------- 5. Add item id to purchase history views, for a per-item price/vendor lookup in the app ----------

drop view if exists materials_purchase_history;
create view materials_purchase_history as
select
  mp.id,
  mp.material_id,
  mp.purchase_date,
  m.name as material_name,
  mp.entry_type,
  mp.quantity,
  m.unit,
  mp.cost_amount as base_cost,
  mp.unit_cost,
  mp.gst_percent,
  mp.gst_amount,
  mp.transport_cost,
  mp.total_landed_cost,
  mp.supplier,
  mp.invoice_ref,
  mp.remarks,
  mp.created_at
from materials_purchases mp
join materials m on m.id = mp.material_id
order by mp.purchase_date desc, mp.created_at desc;

drop view if exists chemical_purchase_history;
create view chemical_purchase_history as
select
  cp.id,
  cp.chemical_id,
  cp.purchase_date,
  c.name as chemical_name,
  cp.entry_type,
  cp.quantity,
  c.unit,
  cp.cost_amount as base_cost,
  cp.unit_cost,
  cp.gst_percent,
  cp.gst_amount,
  cp.transport_cost,
  cp.total_landed_cost,
  cp.supplier,
  cp.invoice_ref,
  cp.remarks,
  cp.created_at
from chemical_purchases cp
join chemicals c on c.id = cp.chemical_id
order by cp.purchase_date desc, cp.created_at desc;

drop view if exists solutions_log_history;
create view solutions_log_history as
select
  sl.id,
  sl.solution_id,
  sl.log_date,
  s.name as solution_name,
  sl.log_type,
  sl.litres,
  sl.bottles,
  s.bottle_size_ml,
  sl.cost_amount as base_cost,
  sl.unit_cost,
  sl.gst_percent,
  sl.gst_amount,
  sl.transport_cost,
  sl.ingredient_cost,
  sl.total_landed_cost,
  sl.batch_ref,
  sl.prepared_by,
  sl.cost_notes,
  sl.created_at
from solutions_log sl
join solutions s on s.id = sl.solution_id
order by sl.log_date desc, sl.created_at desc;
