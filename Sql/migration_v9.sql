-- ============================================================
-- ECOVEX INVENTORY — migration v9
-- Run in Supabase SQL editor after v8.
--
-- Reworks how cost is entered on EVERY purchase (Chemicals,
-- Materials, and Solutions "Purchased" entries):
--
-- OLD: you had to already know cost per gram/ml/litre.
-- NEW: you enter what you actually know — total amount paid for
--      the quantity you bought — and the system works out the
--      per-unit cost itself.
--
-- Also makes the cost breakdown explicit and queryable at every
-- stage: Base Cost -> + GST amount -> + Transport -> = Landed Cost,
-- instead of one opaque total.
--
-- Existing entries are backfilled so nothing you've already
-- logged changes or breaks.
-- ============================================================

-- ============ MATERIALS PURCHASES ============

alter table materials_purchases add column if not exists cost_amount numeric not null default 0;

-- backfill: carry over what was already there (quantity × old unit_cost)
update materials_purchases
set cost_amount = quantity * coalesce(unit_cost, 0)
where cost_amount = 0 and unit_cost > 0;

-- unit_cost is now CALCULATED from cost_amount, not typed in
create or replace function fn_materials_purchase_costing()
returns trigger language plpgsql as $$
begin
  new.unit_cost := case when new.quantity > 0 then round(new.cost_amount / new.quantity, 4) else 0 end;
  return new;
end;
$$;

drop trigger if exists trg_materials_purchase_costing on materials_purchases;
create trigger trg_materials_purchase_costing
  before insert or update on materials_purchases
  for each row execute function fn_materials_purchase_costing();

alter table materials_purchases drop column if exists total_landed_cost cascade;
alter table materials_purchases drop column if exists gst_amount cascade;
alter table materials_purchases add column gst_amount numeric generated always as (
  round(cost_amount * coalesce(gst_percent, 0) / 100.0, 2)
) stored;
alter table materials_purchases add column total_landed_cost numeric generated always as (
  cost_amount + round(cost_amount * coalesce(gst_percent, 0) / 100.0, 2) + coalesce(transport_cost, 0)
) stored;

-- ============ CHEMICAL PURCHASES ============

alter table chemical_purchases add column if not exists cost_amount numeric not null default 0;

update chemical_purchases
set cost_amount = quantity * coalesce(unit_cost, 0)
where cost_amount = 0 and unit_cost > 0;

create or replace function fn_chemical_purchase_costing()
returns trigger language plpgsql as $$
begin
  new.unit_cost := case when new.quantity > 0 then round(new.cost_amount / new.quantity, 6) else 0 end;
  return new;
end;
$$;

drop trigger if exists trg_chemical_purchase_costing on chemical_purchases;
create trigger trg_chemical_purchase_costing
  before insert or update on chemical_purchases
  for each row execute function fn_chemical_purchase_costing();

alter table chemical_purchases drop column if exists total_landed_cost cascade;
alter table chemical_purchases drop column if exists gst_amount cascade;
alter table chemical_purchases add column gst_amount numeric generated always as (
  round(cost_amount * coalesce(gst_percent, 0) / 100.0, 2)
) stored;
alter table chemical_purchases add column total_landed_cost numeric generated always as (
  cost_amount + round(cost_amount * coalesce(gst_percent, 0) / 100.0, 2) + coalesce(transport_cost, 0)
) stored;

-- Note: fn_update_chemical_price_on_purchase (from v8) reads NEW.unit_cost
-- in an AFTER trigger — it still works correctly because the BEFORE
-- trigger above computes unit_cost before the AFTER trigger runs.

-- ============ SOLUTIONS LOG (Purchased entries only — Prepared is unaffected, still auto-costed from its formula) ============

alter table solutions_log add column if not exists cost_amount numeric not null default 0;
alter table solutions_log add column if not exists gst_amount numeric not null default 0;

update solutions_log
set cost_amount = litres * coalesce(unit_cost, 0)
where cost_amount = 0 and unit_cost > 0 and log_type <> 'Prepared';

create or replace function fn_solutions_log_litres()
returns trigger language plpgsql as $$
declare
  v_bottle_size numeric;
  v_base_litres numeric;
begin
  select bottle_size_ml into v_bottle_size from solutions where id = new.solution_id;

  if new.litres is not null then
    new.bottles := round(new.litres / (v_bottle_size / 1000.0), 2);
  elsif new.bottles is not null then
    new.litres := round(new.bottles * v_bottle_size / 1000.0, 2);
  end if;

  if new.log_type = 'Prepared' and new.formula_id is not null then
    select base_batch_litres into v_base_litres from formulas where id = new.formula_id;

    select coalesce(sum(fi.qty_per_batch * (new.litres / v_base_litres) * coalesce(cs.avg_unit_cost, 0)), 0)
      into new.ingredient_cost
      from formula_ingredients fi
      left join chemical_stock cs on cs.id = fi.chemical_id
      where fi.formula_id = new.formula_id;

    new.gst_amount := 0; -- GST already embedded in what you paid for the chemicals themselves
    new.total_landed_cost := coalesce(new.ingredient_cost, 0) + coalesce(new.transport_cost, 0);
  else
    new.unit_cost := case when new.litres > 0 then round(new.cost_amount / new.litres, 4) else 0 end;
    new.gst_amount := round(coalesce(new.cost_amount, 0) * coalesce(new.gst_percent, 0) / 100.0, 2);
    new.total_landed_cost := coalesce(new.cost_amount, 0) + new.gst_amount + coalesce(new.transport_cost, 0);
  end if;

  return new;
end;
$$;

-- (trigger trg_solutions_log_litres already points at this function — no need to redrop/recreate it)

-- ============ HISTORY VIEWS — explicit cost breakdown ============

drop view if exists materials_purchase_history;
create view materials_purchase_history as
select
  mp.id,
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
