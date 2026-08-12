-- ============================================================
-- ECOVEX INVENTORY — migration v8
-- Run in Supabase SQL editor after v7.
--
-- 1. FIXES A BUG: the Prepared-batch trigger referenced a column
--    "chemical_id" on the chemical_stock view that doesn't exist
--    (the view calls it "id") — this is why Prepared entries with
--    a formula were failing with "column cs.chemical_id does not
--    exist". Fixed below.
-- 2. Adds a directly-editable "current price" per chemical, instead
--    of only ever deriving it from purchase history — so you can
--    correct a price the moment it changes without needing to log
--    a fake purchase. Logging a real Purchase (not Opening Stock)
--    still auto-updates this to the latest price you paid.
-- ============================================================

-- ---------- 1. Editable current price per chemical ----------

alter table chemicals add column if not exists current_unit_cost numeric not null default 0;

-- one-time backfill: carry over whatever the weighted-average cost
-- from purchase history already was, so nothing resets to zero
update chemicals c
set current_unit_cost = coalesce((
  select round(sum(cp.total_landed_cost) / sum(cp.quantity), 4)
  from chemical_purchases cp
  where cp.chemical_id = c.id and cp.quantity > 0
), 0)
where c.current_unit_cost = 0;

-- when you log a real Purchase, keep the chemical's current price in sync automatically
create or replace function fn_update_chemical_price_on_purchase()
returns trigger language plpgsql as $$
begin
  if new.entry_type = 'Purchase' and new.unit_cost > 0 then
    update chemicals set current_unit_cost = new.unit_cost where id = new.chemical_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_update_chemical_price on chemical_purchases;
create trigger trg_update_chemical_price
  after insert on chemical_purchases
  for each row execute function fn_update_chemical_price_on_purchase();

-- ---------- 2. Chemical stock view now reads the editable current price ----------

create or replace view chemical_stock as
select
  c.id,
  c.name,
  c.alt_name,
  c.unit,
  coalesce((select sum(cp.quantity) from chemical_purchases cp where cp.chemical_id = c.id), 0) as total_purchased,
  coalesce((select sum(cu.qty_used) from chemical_usage_log cu where cu.chemical_id = c.id), 0) as total_used,
  coalesce((select sum(cp.quantity) from chemical_purchases cp where cp.chemical_id = c.id), 0)
    - coalesce((select sum(cu.qty_used) from chemical_usage_log cu where cu.chemical_id = c.id), 0) as available_qty,
  c.current_unit_cost as avg_unit_cost,
  c.reorder_level,
  case when
    (coalesce((select sum(cp.quantity) from chemical_purchases cp where cp.chemical_id = c.id), 0)
    - coalesce((select sum(cu.qty_used) from chemical_usage_log cu where cu.chemical_id = c.id), 0))
    <= c.reorder_level
  then 'Reorder' else 'OK' end as status
from chemicals c
order by c.name;

-- ---------- 3. THE ACTUAL BUG FIX: correct column reference in both triggers ----------

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

    new.total_landed_cost := coalesce(new.ingredient_cost, 0) + coalesce(new.transport_cost, 0);
  else
    new.total_landed_cost :=
      coalesce(new.litres, 0) * coalesce(new.unit_cost, 0)
      + round(coalesce(new.litres, 0) * coalesce(new.unit_cost, 0) * coalesce(new.gst_percent, 0) / 100.0, 2)
      + coalesce(new.transport_cost, 0);
  end if;

  return new;
end;
$$;

create or replace function fn_consume_chemicals_on_prepare()
returns trigger language plpgsql as $$
declare
  v_base_litres numeric;
begin
  if new.log_type = 'Prepared' and new.formula_id is not null then
    select base_batch_litres into v_base_litres from formulas where id = new.formula_id;

    insert into chemical_usage_log (solutions_log_id, chemical_id, qty_used, unit_cost_at_time, cost)
    select
      new.id,
      fi.chemical_id,
      fi.qty_per_batch * (new.litres / v_base_litres),
      coalesce(cs.avg_unit_cost, 0),
      fi.qty_per_batch * (new.litres / v_base_litres) * coalesce(cs.avg_unit_cost, 0)
    from formula_ingredients fi
    left join chemical_stock cs on cs.id = fi.chemical_id
    where fi.formula_id = new.formula_id;
  end if;
  return new;
end;
$$;
-- (triggers trg_solutions_log_litres and trg_consume_chemicals_on_prepare
-- already point at these functions from migration_v7 — CREATE OR REPLACE
-- above updates their behavior in place, no need to redrop/recreate them.)
