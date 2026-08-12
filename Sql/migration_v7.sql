-- ============================================================
-- ECOVEX INVENTORY — migration v7
-- Run in Supabase SQL editor after v2–v6.
--
-- Adds a completely separate CHEMICALS inventory (raw ingredients
-- used to prepare your own solutions), FORMULAS linking a solution
-- to its ingredient list, and automatic chemical stock deduction +
-- batch costing whenever you log a Prepared solution.
--
-- Seeded with your actual current chemical stock levels and per-unit
-- costs, taken from your tracker spreadsheet and pricing sheet, and
-- three formulas (Tyre Polish 5L, Glass Cleaner 1L, Body Wash 1L)
-- taken directly from your SOP documents.
-- ============================================================

-- ---------- 1. Chemicals master list ----------

create table if not exists chemicals (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  alt_name text,
  unit text not null default 'g', -- display label only, g/ml treated ~1:1 same as your own sheet
  reorder_level numeric not null default 0,
  created_at timestamptz not null default now()
);

-- ---------- 2. Chemical purchases / opening stock ----------

create table if not exists chemical_purchases (
  id uuid primary key default gen_random_uuid(),
  chemical_id uuid not null references chemicals(id),
  purchase_date date not null default current_date,
  entry_type text not null default 'Purchase' check (entry_type in ('Purchase', 'Opening Stock')),
  quantity numeric not null,
  unit_cost numeric not null default 0,   -- cost per g/ml, before GST
  gst_percent numeric not null default 0,
  transport_cost numeric not null default 0,
  total_landed_cost numeric generated always as (
    quantity * coalesce(unit_cost, 0)
    + round(quantity * coalesce(unit_cost, 0) * coalesce(gst_percent, 0) / 100.0, 2)
    + coalesce(transport_cost, 0)
  ) stored,
  supplier text,
  invoice_ref text,
  remarks text,
  created_at timestamptz not null default now()
);

-- ---------- 3. Formulas (one per solution, can have more than one version) ----------

create table if not exists formulas (
  id uuid primary key default gen_random_uuid(),
  solution_id uuid not null references solutions(id),
  name text not null,
  base_batch_litres numeric not null,
  version text,
  is_active boolean not null default true,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists formula_ingredients (
  id uuid primary key default gen_random_uuid(),
  formula_id uuid not null references formulas(id) on delete cascade,
  chemical_id uuid not null references chemicals(id),
  qty_per_batch numeric not null check (qty_per_batch > 0),
  notes text
);

-- ---------- 4. Link solutions_log to a formula + track ingredient cost ----------

alter table solutions_log add column if not exists formula_id uuid references formulas(id);
alter table solutions_log add column if not exists ingredient_cost numeric default 0;

-- ---------- 5. Chemical usage log — the actual deduction record ----------
-- One row per ingredient consumed by a specific Prepared batch. Deleting
-- the solutions_log row (e.g. correcting a mistaken entry) cascades and
-- reverses the deduction automatically.

create table if not exists chemical_usage_log (
  id uuid primary key default gen_random_uuid(),
  solutions_log_id uuid not null references solutions_log(id) on delete cascade,
  chemical_id uuid not null references chemicals(id),
  qty_used numeric not null,
  unit_cost_at_time numeric not null default 0,
  cost numeric not null default 0,
  created_at timestamptz not null default now()
);

-- ---------- 6. Chemical stock view (weighted-average cost, reorder alert) ----------

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
  case when coalesce((select sum(cp.quantity) from chemical_purchases cp where cp.chemical_id = c.id), 0) > 0
    then round(
      coalesce((select sum(cp.total_landed_cost) from chemical_purchases cp where cp.chemical_id = c.id), 0)
      / (select sum(cp.quantity) from chemical_purchases cp where cp.chemical_id = c.id), 4)
    else 0 end as avg_unit_cost,
  c.reorder_level,
  case when
    (coalesce((select sum(cp.quantity) from chemical_purchases cp where cp.chemical_id = c.id), 0)
    - coalesce((select sum(cu.qty_used) from chemical_usage_log cu where cu.chemical_id = c.id), 0))
    <= c.reorder_level
  then 'Reorder' else 'OK' end as status
from chemicals c
order by c.name;

-- ---------- 7. Extend the solutions_log trigger: cost a Prepared batch from its formula ----------

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
      left join chemical_stock cs on cs.chemical_id = fi.chemical_id
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

drop trigger if exists trg_solutions_log_litres on solutions_log;
create trigger trg_solutions_log_litres
  before insert or update on solutions_log
  for each row execute function fn_solutions_log_litres();

-- ---------- 8. After a Prepared batch is inserted, deduct every ingredient ----------

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
    left join chemical_stock cs on cs.chemical_id = fi.chemical_id
    where fi.formula_id = new.formula_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_consume_chemicals_on_prepare on solutions_log;
create trigger trg_consume_chemicals_on_prepare
  after insert on solutions_log
  for each row execute function fn_consume_chemicals_on_prepare();

-- ---------- 9. RLS — same open-access pattern as the rest of the app ----------

alter table chemicals enable row level security;
alter table chemical_purchases enable row level security;
alter table formulas enable row level security;
alter table formula_ingredients enable row level security;
alter table chemical_usage_log enable row level security;

drop policy if exists "Public read/write - chemicals" on chemicals;
create policy "Public read/write - chemicals" on chemicals for all using (true) with check (true);
drop policy if exists "Public read/write - chemical_purchases" on chemical_purchases;
create policy "Public read/write - chemical_purchases" on chemical_purchases for all using (true) with check (true);
drop policy if exists "Public read/write - formulas" on formulas;
create policy "Public read/write - formulas" on formulas for all using (true) with check (true);
drop policy if exists "Public read/write - formula_ingredients" on formula_ingredients;
create policy "Public read/write - formula_ingredients" on formula_ingredients for all using (true) with check (true);
drop policy if exists "Public read/write - chemical_usage_log" on chemical_usage_log;
create policy "Public read/write - chemical_usage_log" on chemical_usage_log for all using (true) with check (true);

-- ---------- 10. History view for chemical purchases ----------

create or replace view chemical_purchase_history as
select
  cp.id,
  cp.purchase_date,
  c.name as chemical_name,
  cp.entry_type,
  cp.quantity,
  c.unit,
  cp.unit_cost,
  cp.gst_percent,
  cp.transport_cost,
  cp.total_landed_cost,
  cp.supplier,
  cp.invoice_ref,
  cp.remarks,
  cp.created_at
from chemical_purchases cp
join chemicals c on c.id = cp.chemical_id
order by cp.purchase_date desc, cp.created_at desc;

-- ============================================================
-- SEED DATA — your real chemicals, current stock, and costs
-- ============================================================

-- Chemicals: name, alt name, unit, reorder level (= largest single-batch
-- requirement across your 3 formulas, from your tracker sheet)
insert into chemicals (name, alt_name, unit, reorder_level) values
  ('Amino Silicone Emulsion', null, 'ml', 900),
  ('Sodium Bicarbonate (baking soda)', 'NaOH', 'g', 1),
  ('Disodium EDTA', null, 'g', 15),
  ('BHT (10% solution in PG)', null, 'ml', 0.5),
  ('C8/C10 APG', 'Caprylyl/Capryl Glucoside (50%)', 'ml', 25),
  ('CAPB', 'Cocamidopropyl Betaine (30%)', 'ml', 20),
  ('Citric Acid (anhydrous)', null, 'g', 3),
  ('Coco Glucoside (APG)', null, 'ml', 60),
  ('Colorant', 'Water-soluble Colour Dye', 'g', 2.5),
  ('Dimethicone 100–350 cSt', 'Silicon Oil', 'g', 175),
  ('Ethylhexylglycerin (99%)', null, 'ml', 2),
  ('Fragrance (water-soluble)', null, 'ml', 2),
  ('GHPTC', 'Guar Hydroxypropyltrimonium Chloride', 'g', 3),
  ('Glycerin (99.5%)', null, 'ml', 50),
  ('HEC', null, 'g', 0),
  ('Isopropyl Alcohol (IPA 99%)', 'IPA (99%)', 'ml', 450),
  ('Lecithin (soya, liquid)', null, 'ml', 125),
  ('PEG-40 Hydrogenated Castor Oil', null, 'ml', 200),
  ('Phenoxyethanol (97-99%)', null, 'ml', 40),
  ('Polyquaternium-7 (50% active)', null, 'ml', 15),
  ('Polysorbate 20 (Tween 20)', null, 'ml', 10),
  ('Polysorbate 80 (Tween 80)', null, 'g', 175),
  ('Potassium Sorbate (food grade)', null, 'g', 20),
  ('Sodium Benzoate', null, 'g', 2),
  ('Propylene Glycol (99.5%)', null, 'ml', 30),
  ('Silicone Emulsion (60% active)', null, 'g', 1250),
  ('Sodium Gluconate', null, 'g', 2),
  ('Xanthan Gum (food/industrial grade)', null, 'g', 25),
  ('Carnauba Wax', null, 'g', 0),
  ('RO / Distilled Water', null, 'ml', 0)
on conflict (name) do nothing;

-- Opening stock: your actual current on-hand quantity (from your tracker
-- sheet's live stock), with per-unit cost from your pricing sheet where
-- known. Cost = 0 where your pricing sheet didn't have that item —
-- edit those in Manage Chemicals > Log Purchase once you know the price.
insert into chemical_purchases (chemical_id, entry_type, quantity, unit_cost, remarks)
select id, 'Opening Stock', v.qty, v.cost, 'Opening stock — carried over from your existing tracker sheet'
from chemicals c
join (values
  ('Amino Silicone Emulsion', 2080, 0.14),
  ('Sodium Bicarbonate (baking soda)', 996, 0),
  ('Disodium EDTA', 70, 0.78),
  ('BHT (10% solution in PG)', 99.5, 1.2),
  ('C8/C10 APG', 475, 2.2),
  ('CAPB', 980, 0.185),
  ('Citric Acid (anhydrous)', 100, 0.7),
  ('Coco Glucoside (APG)', 450, 0.36),
  ('Colorant', 46.5, 0),
  ('Dimethicone 100–350 cSt', 10, 0.68),
  ('Ethylhexylglycerin (99%)', 78, 3.0),
  ('Fragrance (water-soluble)', 8, 0),
  ('GHPTC', 97, 2.9),
  ('Glycerin (99.5%)', 115, 0.32),
  ('HEC', 100, 0),
  ('Isopropyl Alcohol (IPA 99%)', 0, 0.24),
  ('Lecithin (soya, liquid)', 625, 0.24),
  ('PEG-40 Hydrogenated Castor Oil', 245, 0.4),
  ('Phenoxyethanol (97-99%)', 402, 0.44),
  ('Polyquaternium-7 (50% active)', 985, 0.16),
  ('Polysorbate 20 (Tween 20)', 490, 0.3),
  ('Polysorbate 80 (Tween 80)', 675, 0.32),
  ('Potassium Sorbate (food grade)', 50, 0.9),
  ('Sodium Benzoate', 78, 0.6),
  ('Propylene Glycol (99.5%)', 10, 0.51),
  ('Silicone Emulsion (60% active)', 250, 0.24),
  ('Sodium Gluconate', 98, 0.5),
  ('Xanthan Gum (food/industrial grade)', 25, 2.3),
  ('Carnauba Wax', 70, 0),
  ('RO / Distilled Water', 20000, 0.025)
) as v(name, qty, cost) on v.name = c.name
where v.qty > 0
on conflict do nothing;

-- ---------- Formulas + ingredients, from your SOP documents ----------

-- Glass Cleaner — 1L batch (Glass_Cleaner_SOP_Rev2)
insert into formulas (solution_id, name, base_batch_litres, version, notes)
select id, 'Glass Cleaner — Standard 1L', 1, 'Rev 2.0', 'From Glass_Cleaner_SOP_Rev2.docx'
from solutions where name = 'Glass Cleaning Solution'
on conflict do nothing;

insert into formula_ingredients (formula_id, chemical_id, qty_per_batch)
select f.id, c.id, v.qty
from formulas f
join (values
  ('RO / Distilled Water', 457),
  ('Isopropyl Alcohol (IPA 99%)', 450),
  ('Coco Glucoside (APG)', 60),
  ('Disodium EDTA', 15),
  ('Citric Acid (anhydrous)', 3),
  ('Phenoxyethanol (97-99%)', 5),
  ('Glycerin (99.5%)', 10)
) as v(cname, qty) on true
join chemicals c on c.name = v.cname
where f.name = 'Glass Cleaner — Standard 1L';

-- Tyre Polish — 5L batch (Ecovex_TyrePolish_V4_1_5L_AminoAdj — 20% active amino silicone version)
insert into formulas (solution_id, name, base_batch_litres, version, notes)
select id, 'Tyre Polish — V4.1 5L (20% amino silicone)', 5, 'V4.1', 'From Ecovex_TyrePolish_V4_1_5L_AminoAdj.docx — uses 900g Amino Silicone Emulsion for 20%-active stock'
from solutions where name = 'Tyre Polish'
on conflict do nothing;

insert into formula_ingredients (formula_id, chemical_id, qty_per_batch)
select f.id, c.id, v.qty
from formulas f
join (values
  ('RO / Distilled Water', 2077),
  ('Sodium Bicarbonate (baking soda)', 1),
  ('Disodium EDTA', 10),
  ('Xanthan Gum (food/industrial grade)', 25),
  ('Glycerin (99.5%)', 50),
  ('Isopropyl Alcohol (IPA 99%)', 150),
  ('PEG-40 Hydrogenated Castor Oil', 200),
  ('Polysorbate 80 (Tween 80)', 175),
  ('Lecithin (soya, liquid)', 125),
  ('Silicone Emulsion (60% active)', 1250),
  ('Amino Silicone Emulsion', 900),
  ('Dimethicone 100–350 cSt', 175),
  ('Phenoxyethanol (97-99%)', 40),
  ('Potassium Sorbate (food grade)', 20),
  ('Colorant', 2.5)
) as v(cname, qty) on true
join chemicals c on c.name = v.cname
where f.name = 'Tyre Polish — V4.1 5L (20% amino silicone)';

-- Body Wash — 1L batch (Waterless_CarWash_SOP_1L)
insert into formulas (solution_id, name, base_batch_litres, version, notes)
select id, 'Body Wash — Standard 1L', 1, '1.0', 'From Waterless_CarWash_SOP_1L.docx'
from solutions where name = 'Body Wash Solution'
on conflict do nothing;

insert into formula_ingredients (formula_id, chemical_id, qty_per_batch)
select f.id, c.id, v.qty
from formulas f
join (values
  ('RO / Distilled Water', 455),
  ('Propylene Glycol (99.5%)', 30),
  ('Glycerin (99.5%)', 35),
  ('Polyquaternium-7 (50% active)', 15),
  ('GHPTC', 3),
  ('Sodium Gluconate', 2),
  ('C8/C10 APG', 25),
  ('Sodium Benzoate', 2),
  ('PEG-40 Hydrogenated Castor Oil', 55),
  ('Polysorbate 20 (Tween 20)', 10),
  ('Amino Silicone Emulsion', 220),
  ('Dimethicone 100–350 cSt', 15),
  ('BHT (10% solution in PG)', 0.5),
  ('Coco Glucoside (APG)', 50),
  ('CAPB', 20),
  ('Phenoxyethanol (97-99%)', 8),
  ('Ethylhexylglycerin (99%)', 2),
  ('Fragrance (water-soluble)', 2)
) as v(cname, qty) on true
join chemicals c on c.name = v.cname
where f.name = 'Body Wash — Standard 1L';
