-- ============================================================
-- ECOVEX INVENTORY — migration v4
-- Run in Supabase SQL editor AFTER v2 and v3. Safe to re-run.
--
-- 1. Solutions: you now enter LITRES, bottles is calculated for you
--    (reversed from before).
-- 2. Full landed cost on both materials and solutions: unit cost +
--    GST% + flat transport charge = total landed cost, auto-calculated.
-- 3. History views so you can see every purchase/prep entry with
--    who/what/when/why, not just the current stock totals.
-- ============================================================

-- ---------- 1. Materials Purchases — landed cost ----------

alter table materials_purchases add column if not exists gst_percent numeric default 0;
alter table materials_purchases add column if not exists transport_cost numeric default 0;

-- drop first in case this migration is re-run with a changed formula
alter table materials_purchases drop column if exists total_landed_cost;
alter table materials_purchases add column total_landed_cost numeric generated always as (
  quantity * coalesce(unit_cost, 0)
  + round(quantity * coalesce(unit_cost, 0) * coalesce(gst_percent, 0) / 100.0, 2)
  + coalesce(transport_cost, 0)
) stored;

-- ---------- 2. Solutions Log — litres-first entry + landed cost ----------

alter table solutions_log alter column bottles drop not null; -- now calculated, not entered
alter table solutions_log add column if not exists unit_cost numeric default 0;   -- cost per litre
alter table solutions_log add column if not exists gst_percent numeric default 0;
alter table solutions_log add column if not exists transport_cost numeric default 0;
alter table solutions_log add column if not exists total_landed_cost numeric default 0;

create or replace function fn_solutions_log_litres()
returns trigger language plpgsql as $$
declare
  v_bottle_size numeric;
begin
  select bottle_size_ml into v_bottle_size from solutions where id = new.solution_id;

  if new.litres is not null then
    -- litres is the input; back-calculate bottles for reference
    new.bottles := round(new.litres / (v_bottle_size / 1000.0), 2);
  elsif new.bottles is not null then
    -- fallback if a bottles value ever comes in directly
    new.litres := round(new.bottles * v_bottle_size / 1000.0, 2);
  end if;

  new.total_landed_cost :=
    coalesce(new.litres, 0) * coalesce(new.unit_cost, 0)
    + round(coalesce(new.litres, 0) * coalesce(new.unit_cost, 0) * coalesce(new.gst_percent, 0) / 100.0, 2)
    + coalesce(new.transport_cost, 0);

  return new;
end;
$$;

drop trigger if exists trg_solutions_log_litres on solutions_log;
create trigger trg_solutions_log_litres
  before insert or update on solutions_log
  for each row execute function fn_solutions_log_litres();

-- ---------- 3. History views — "when did I buy/prep this, and why" ----------

create or replace view materials_purchase_history as
select
  mp.id,
  mp.purchase_date,
  m.name as material_name,
  mp.quantity,
  m.unit,
  mp.unit_cost,
  mp.gst_percent,
  mp.transport_cost,
  mp.total_landed_cost,
  mp.supplier,
  mp.invoice_ref,
  mp.remarks,
  mp.created_at
from materials_purchases mp
join materials m on m.id = mp.material_id
order by mp.purchase_date desc, mp.created_at desc;

create or replace view solutions_log_history as
select
  sl.id,
  sl.log_date,
  s.name as solution_name,
  sl.log_type,
  sl.litres,
  sl.bottles,
  s.bottle_size_ml,
  sl.unit_cost,
  sl.gst_percent,
  sl.transport_cost,
  sl.total_landed_cost,
  sl.batch_ref,
  sl.prepared_by,
  sl.cost_notes,
  sl.created_at
from solutions_log sl
join solutions s on s.id = sl.solution_id
order by sl.log_date desc, sl.created_at desc;
