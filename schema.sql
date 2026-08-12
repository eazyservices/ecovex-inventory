-- ============================================================
-- ECOVEX INVENTORY — Supabase schema
-- Mirrors Ecovex_Inventory_Master_v4.xlsm 1:1:
--   Materials Purchased -> materials_purchases
--   Solutions Log       -> solutions_log
--   Issuance Log        -> issuance_log
--   Stock - Materials   -> view: stock_materials
--   Stock - Solutions   -> view: stock_solutions
-- Run this once in the Supabase SQL editor. If you already have
-- tables with different names, treat this as a reference and
-- rename the FK columns in the app code to match yours.
-- ============================================================

-- ---------- Reference tables (replace _Lists sheet + dropdowns) ----------

create table if not exists materials (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  unit text not null default 'Pcs',
  reorder_level numeric not null default 5,
  created_at timestamptz not null default now()
);

create table if not exists solutions (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  bottle_size_ml numeric not null,
  reorder_level_l numeric not null default 1,
  created_at timestamptz not null default now()
);

create table if not exists attendants (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true
);

-- ---------- Purchases / prep logs ----------

create table if not exists materials_purchases (
  id uuid primary key default gen_random_uuid(),
  material_id uuid not null references materials(id),
  purchase_date date not null default current_date,
  quantity numeric not null,
  supplier text,
  invoice_ref text,
  unit_cost numeric default 0,
  total_cost numeric generated always as (quantity * coalesce(unit_cost, 0)) stored,
  remarks text,
  created_at timestamptz not null default now()
);

create table if not exists solutions_log (
  id uuid primary key default gen_random_uuid(),
  solution_id uuid not null references solutions(id),
  log_type text not null check (log_type in ('Purchased', 'Prepared')),
  log_date date not null default current_date,
  bottles numeric not null,
  litres numeric, -- auto-filled by trigger below, mirrors "Litres Added (auto)"
  batch_ref text,
  cost_notes text,
  prepared_by text,
  created_at timestamptz not null default now()
);

create or replace function fn_solutions_log_litres()
returns trigger language plpgsql as $$
begin
  select new.bottles * s.bottle_size_ml / 1000.0 into new.litres
  from solutions s where s.id = new.solution_id;
  return new;
end;
$$;

drop trigger if exists trg_solutions_log_litres on solutions_log;
create trigger trg_solutions_log_litres
  before insert or update on solutions_log
  for each row execute function fn_solutions_log_litres();

-- ---------- Issuance log (the "Issue Entry" kit form writes here) ----------

create table if not exists issuance_log (
  id uuid primary key default gen_random_uuid(),
  issue_date date not null default current_date,
  attendant text not null,
  category text not null check (category in ('Material', 'Solution')),
  material_id uuid references materials(id),
  solution_id uuid references solutions(id),
  qty_issued numeric not null check (qty_issued > 0),
  litres_issued numeric, -- auto-filled for Solution rows
  issued_by text,
  remarks text,
  created_at timestamptz not null default now(),
  check (
    (category = 'Material' and material_id is not null and solution_id is null) or
    (category = 'Solution' and solution_id is not null and material_id is null)
  )
);

create or replace function fn_issuance_litres()
returns trigger language plpgsql as $$
begin
  if new.category = 'Solution' then
    select new.qty_issued * s.bottle_size_ml / 1000.0 into new.litres_issued
    from solutions s where s.id = new.solution_id;
  else
    new.litres_issued := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_issuance_litres on issuance_log;
create trigger trg_issuance_litres
  before insert or update on issuance_log
  for each row execute function fn_issuance_litres();

-- ---------- Live stock views (replace the SUMIF/SUMIFS formula sheets) ----------

create or replace view stock_materials as
select
  m.id,
  m.name as material_name,
  m.unit,
  coalesce((select sum(mp.quantity) from materials_purchases mp where mp.material_id = m.id), 0) as total_purchased,
  coalesce((select sum(il.qty_issued) from issuance_log il where il.material_id = m.id and il.category = 'Material'), 0) as total_issued,
  coalesce((select sum(mp.quantity) from materials_purchases mp where mp.material_id = m.id), 0)
    - coalesce((select sum(il.qty_issued) from issuance_log il where il.material_id = m.id and il.category = 'Material'), 0) as available_stock,
  m.reorder_level,
  case when
    coalesce((select sum(mp.quantity) from materials_purchases mp where mp.material_id = m.id), 0)
    - coalesce((select sum(il.qty_issued) from issuance_log il where il.material_id = m.id and il.category = 'Material'), 0)
    <= m.reorder_level
  then 'Reorder' else 'OK' end as status
from materials m
order by m.name;

create or replace view stock_solutions as
select
  s.id,
  s.name as solution_name,
  s.bottle_size_ml,
  coalesce((select sum(sl.litres) from solutions_log sl where sl.solution_id = s.id), 0) as total_in_l,
  coalesce((select sum(il.litres_issued) from issuance_log il where il.solution_id = s.id and il.category = 'Solution'), 0) as total_issued_l,
  coalesce((select sum(sl.litres) from solutions_log sl where sl.solution_id = s.id), 0)
    - coalesce((select sum(il.litres_issued) from issuance_log il where il.solution_id = s.id and il.category = 'Solution'), 0) as available_l,
  s.reorder_level_l,
  case when
    coalesce((select sum(sl.litres) from solutions_log sl where sl.solution_id = s.id), 0)
    - coalesce((select sum(il.litres_issued) from issuance_log il where il.solution_id = s.id and il.category = 'Solution'), 0)
    <= s.reorder_level_l
  then 'Reorder' else 'OK' end as status
from solutions s
order by s.name;

-- ---------- Seed data (from your _Lists / Stock sheets) ----------

insert into materials (name, unit, reorder_level) values
  ('Dusting Brush – Regular', 'Pcs', 5),
  ('Dusting Brush – Wax Coated', 'Pcs', 5),
  ('Microfiber Clothes', 'Pcs', 50),
  ('Glass Cleaner Clothes', 'Pcs', 5),
  ('Buffing Clothes', 'Pcs', 5),
  ('Spray Pump', 'Pcs', 5),
  ('Spray Bottles', 'Pcs', 5),
  ('Tyre Brush', 'Pcs', 5),
  ('Carpet Brush', 'Pcs', 5),
  ('Internal Cleaning Brush', 'Pcs', 5),
  ('Dust Pan & Brush', 'Set', 5),
  ('Vacuum Cleaner', 'Pcs', 5),
  ('T-Shirt', 'Pcs', 5),
  ('Bag', 'Pcs', 5),
  ('Applicators', 'Pcs', 5)
on conflict (name) do nothing;

insert into solutions (name, bottle_size_ml, reorder_level_l) values
  ('Body Wash Solution', 100, 1),
  ('Glass Cleaning Solution', 100, 1),
  ('Tyre Polish', 500, 1),
  ('Dashboard Polish', 200, 1),
  ('Microfiber Cleaner', 200, 1)
on conflict (name) do nothing;

insert into attendants (name) values
  ('Attendant 1'), ('Attendant 2'), ('Attendant 3'), ('Attendant 4'), ('Attendant 5')
on conflict (name) do nothing;

-- ---------- Row Level Security ----------
-- Enable and add policies matching how your app authenticates
-- (e.g. allow all for authenticated users). Left open here since
-- your existing project likely already has an RLS/auth pattern.

alter table materials enable row level security;
alter table solutions enable row level security;
alter table attendants enable row level security;
alter table materials_purchases enable row level security;
alter table solutions_log enable row level security;
alter table issuance_log enable row level security;

create policy "Authenticated read/write - materials" on materials for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "Authenticated read/write - solutions" on solutions for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "Authenticated read/write - attendants" on attendants for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "Authenticated read/write - materials_purchases" on materials_purchases for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "Authenticated read/write - solutions_log" on solutions_log for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "Authenticated read/write - issuance_log" on issuance_log for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
