-- ============================================================
-- ECOVEX INVENTORY — migration v12
-- Run in Supabase SQL editor after v2–v11 (Sql/migration_v2.sql
-- through Sql/migration_v10.sql, then root migration_v11.sql).
--
-- Adds the two new validated manufacturing SOPs (Tyre Polish V3
-- and Microfiber Cleaner) as real formulas with real ingredient
-- quantities, archives the superseded Tyre Polish V4.1 formula,
-- links formulas to their full SOP document, and adds a view that
-- computes — per active formula, from current chemical stock —
-- the max litres producible right now and which chemical is the
-- bottleneck. This powers the new Manufacturing dashboard's
-- Production Capacity panel and Shopping List builder.
-- ============================================================

-- ---------- 1. New chemicals introduced by the two new SOPs ----------
-- These are a genuinely different spec from anything already in the
-- Chemicals list (different concentration or a different substance
-- entirely), so they're tracked as their own stock items rather than
-- folded into an existing one. Opening stock is 0 — log real
-- purchases under Chemicals > Log Purchase once you have them on hand.
-- Reorder level is set to roughly one 1L batch's worth as a starting
-- point; adjust in Manage Chemicals once you know your real usage.
--
-- NOTE: 'Isopropyl Alcohol (IPA) (90%)' and 'SLES 28% Active' are NOT
-- listed here — they already exist in your live Chemicals list (added
-- since the last migration file was written) and are reused below.

insert into chemicals (name, alt_name, unit, reorder_level) values
  ('Vegetable Glycerin', null, 'ml', 15),
  ('Sodium Chloride (fine salt)', 'Table Salt, fine', 'g', 20),
  ('Tea Tree Oil', null, 'ml', 1),
  ('Citric Acid (50% solution)', null, 'g', 5),
  ('Fragrance Oil (Lemon or Tea Tree)', null, 'ml', 2)
on conflict (name) do nothing;

-- ---------- 2. Link a formula to its full manufacturing SOP page ----------

alter table formulas add column if not exists manual_url text;

-- ---------- 3. Archive the superseded Tyre Polish formula ----------
-- Kept for history — just stops being used for stock deduction and
-- the production calculator below.

update formulas set is_active = false where name = 'Tyre Polish — V4.1 5L (20% amino silicone)';

-- ---------- 4. Tyre Polish V3 (Rev 3.0) — 1L base, 15 ingredients ----------
-- Values are the manual's per-litre figures; the two RO Water entries
-- (start + top-up) are combined into one ingredient row.

insert into formulas (solution_id, name, base_batch_litres, version, notes, manual_url, is_active)
select id, 'Tyre Polish — V3 (Rev 3.0)', 1, 'V3 / Rev 3.0',
  'Validated master manufacturing file — 5-phase batch (chelated water base, xanthan rheology, 3-component emulsifier system, silicone backbone, preservation/pH/fill). See the linked SOP for the full step-by-step procedure, QC checks and costing.',
  'manuals/tyre-polish-v3.html', true
from solutions where name = 'Tyre Polish'
on conflict do nothing;

insert into formula_ingredients (formula_id, chemical_id, qty_per_batch, notes)
select f.id, c.id, v.qty, v.note
from formulas f
join (values
  ('RO / Distilled Water', 470.5, 'Combines 430 g/L start + 40.5 g/L top-up from the SOP'),
  ('Disodium EDTA', 2.0, null),
  ('Xanthan Gum (food/industrial grade)', 4.0, null),
  ('Isopropyl Alcohol (IPA 99%)', 30.0, null),
  ('PEG-40 Hydrogenated Castor Oil', 40.0, null),
  ('Polysorbate 80 (Tween 80)', 35.0, null),
  ('Lecithin (soya, liquid)', 20.0, null),
  ('Silicone Emulsion (60% active)', 250.0, 'Real drums run 55-60% active per COA — see manual section 04 for the active% adjustment table'),
  ('Amino Silicone Emulsion', 100.0, null),
  ('Dimethicone 100–350 cSt', 30.0, null),
  ('Phenoxyethanol (97-99%)', 8.0, null),
  ('Potassium Sorbate (food grade)', 3.0, null),
  ('Citric Acid (50% solution)', 5.0, null),
  ('Colorant', 0.5, null),
  ('Fragrance Oil (Lemon or Tea Tree)', 2.0, null)
) as v(cname, qty, note) on true
join chemicals c on c.name = v.cname
where f.name = 'Tyre Polish — V3 (Rev 3.0)'
on conflict do nothing;

-- ---------- 5. Microfiber Cleaner — Master Batch (Rev 5.0) — 1L base, 12 ingredients ----------
-- Ranges in the manual (EDTA, Tea Tree Oil, salt) are seeded at one
-- representative point with the full range kept in the ingredient's
-- notes. RO Water is the remainder to reach exactly 1000 ml/L.
--
-- This is a SEPARATE, ADDITIONAL formula for the Microfiber Cleaner
-- solution — your live data already has an active formula for it
-- ("Bulletproof All-in-One Microfiber Cleaner", V2.0, simpler recipe
-- without the salt-curve thickening or Tea Tree Oil). It's left
-- untouched/active here since nobody asked to retire it; your data
-- already has this same multiple-active-formulas-per-solution pattern
-- for Glass Cleaning Solution. Archive it yourself from the Formulas
-- page if you want this new one to be the only one in use.
--
-- SLES is dosed using the SOP's own "28% strength" alternate rate
-- (150 g/L) against your existing 'SLES 28% Active' chemical, since
-- that's what's actually in stock (matches what the existing
-- Bulletproof formula already assumes). IPA reuses your existing
-- 'Isopropyl Alcohol (IPA) (90%)' chemical.

insert into formulas (solution_id, name, base_batch_litres, version, notes, manual_url, is_active)
select id, 'Microfiber Cleaner — Master Batch (Rev 5.0)', 1, 'Rev 5.0',
  'Validated master batch manual — all-in-one concentrate for hand wash, top-load and front-load use. See the linked SOP for the full step-by-step procedure, dosage and troubleshooting.',
  'manuals/microfiber-cleaner.html', true
from solutions where name = 'Microfiber Cleaner'
on conflict do nothing;

insert into formula_ingredients (formula_id, chemical_id, qty_per_batch, notes)
select f.id, c.id, v.qty, v.note
from formulas f
join (values
  ('RO / Distilled Water', 790.5, 'Remainder to reach exactly 1000 ml/L after every other ingredient'),
  ('SLES 28% Active', 150.0, 'SOP''s 28%-strength alternate dosage (150 g/L) — matches what''s actually stocked'),
  ('CAPB', 40.0, null),
  ('Disodium EDTA', 2.2, 'Range 2.0-2.4 g/L in the SOP'),
  ('Citric Acid (anhydrous)', 5.0, 'pH trim'),
  ('Isopropyl Alcohol (IPA) (90%)', 62.2, null),
  ('Vegetable Glycerin', 15.0, null),
  ('Polysorbate 20 (Tween 20)', 5.0, 'Premixed with Tea Tree Oil before adding'),
  ('Tea Tree Oil', 0.625, 'Optional — 10-15 drops/L in the SOP (~20 drops/ml)'),
  ('Sodium Benzoate', 1.0, null),
  ('Potassium Sorbate (food grade)', 1.0, null),
  ('Sodium Chloride (fine salt)', 17.5, 'Starts at 6 g/L, titrated up to 15-20 g/L as a 10% brine to reach target consistency — see SOP salt-curve step')
) as v(cname, qty, note) on true
join chemicals c on c.name = v.cname
where f.name = 'Microfiber Cleaner — Master Batch (Rev 5.0)'
on conflict do nothing;

-- ---------- 6. Production capacity view ----------
-- Per active formula: the max litres producible right now if it got
-- 100% of every ingredient's available stock to itself, and which
-- chemical would run out first (the bottleneck). No new tables/RLS
-- needed — reads only the already-open chemicals/formulas tables.

create or replace view formula_max_producible as
select
  f.id as formula_id,
  f.name as formula_name,
  f.solution_id,
  s.name as solution_name,
  f.base_batch_litres,
  f.is_active,
  case when count(fi.id) = 0 then null
    else min(coalesce(cs.available_qty, 0) / fi.qty_per_batch) * f.base_batch_litres
  end as max_litres_now,
  (array_agg(c.name order by coalesce(cs.available_qty, 0) / fi.qty_per_batch asc))[1] as bottleneck_chemical
from formulas f
join solutions s on s.id = f.solution_id
left join formula_ingredients fi on fi.formula_id = f.id
left join chemicals c on c.id = fi.chemical_id
left join chemical_stock cs on cs.id = fi.chemical_id
group by f.id, f.name, f.solution_id, s.name, f.base_batch_litres, f.is_active;
