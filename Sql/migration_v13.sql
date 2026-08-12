-- ============================================================
-- ECOVEX INVENTORY — migration v13
-- Run in Supabase SQL editor after Sql/migration_v12.sql.
--
-- Collapses formulas down to exactly one active formula per
-- solution (archiving the rest), retires "Citric Acid (50%
-- solution)" as a tracked chemical since it's mixed in-house from
-- Citric Acid (anhydrous) + water rather than purchased, and adds
-- the fourth manual (Waterless Car Wash) as the new Body Wash
-- formula.
-- ============================================================

-- ---------- 1. Archive superseded formulas ----------
-- Kept for history — Formulas page now has an Archived section.
-- After this, each of the 4 current products has exactly one
-- active formula: Body Wash Solution (new Waterless Car Wash,
-- inserted below), Ecovex Glass Cleaner Concentrate V4.0 (already
-- the sole formula on "Glass Cleaning Solution V4"), Tyre Polish
-- (V3, from migration_v12), Microfiber Cleaner (Rev 5.0, from
-- migration_v12).

update formulas set is_active = false
where name in (
  'Bulletproof All-in-One Microfiber Cleaner',
  'Glass Cleaner — Standard 1L',
  'Glass_Cleaner_SOP_Rev3_Bulletproof',
  'Body Wash — Standard 1L'
);

-- ---------- 2. Retire "Citric Acid (50% solution)" ----------
-- Not a purchased chemical — it's diluted in-house from Citric Acid
-- (anhydrous) + water. Confirmed zero purchases and zero usage log
-- entries before this migration; only referenced by Tyre Polish
-- V3's Phase E ingredient, which gets re-pointed to the anhydrous
-- chemical at half the quantity (a 50% solution is half citric
-- acid by weight) before the now-unused chemical row is deleted.

update formula_ingredients fi
set chemical_id = (select id from chemicals where name = 'Citric Acid (anhydrous)'),
    qty_per_batch = 2.5,
    notes = 'Re-pointed from the retired ''Citric Acid (50% solution)'' entry — 5.0 g/L of 50% solution = 2.5 g/L anhydrous citric acid, diluted in-house with water at use'
where fi.chemical_id = (select id from chemicals where name = 'Citric Acid (50% solution)')
  and fi.formula_id = (select id from formulas where name = 'Tyre Polish — V3 (Rev 3.0)');

delete from chemicals where name = 'Citric Acid (50% solution)';

-- ---------- 3. Waterless Car Wash — Master Formula (Rev 5.0) ----------
-- Replaces "Body Wash — Standard 1L" as the active Body Wash
-- formula. 1L base. Every ingredient already exists in Chemicals —
-- no new chemicals needed. A1 (initial water charge) + E3 (final
-- top-up) are combined into one RO/Distilled Water row, and A2a +
-- A2b (Propylene Glycol) into one row, matching the pattern used
-- for Tyre Polish V3. D3 (Citric Acid 50% solution, q.s. to pH) is
-- seeded as its anhydrous equivalent per the retirement above.

insert into formulas (solution_id, name, base_batch_litres, version, notes, manual_url, is_active)
select id, 'Waterless Car Wash — Master Formula (Rev 5.0)', 1, 'Rev 5.0',
  'Amino silicone system with anti-separation stabilizer (HEC). Whisk & stick-blender method, 5-phase batch with defined checkpoints and reject criteria. See the linked SOP for the full step-by-step procedure, pH correction guide, and release sign-off checklist.',
  'manuals/waterless-car-wash.html', true
from solutions where name = 'Body Wash Solution'
on conflict do nothing;

insert into formula_ingredients (formula_id, chemical_id, qty_per_batch, notes)
select f.id, c.id, v.qty, v.note
from formulas f
join (values
  ('RO / Distilled Water', 462.5, 'Combines 435 mL initial charge (A1) + 27.5 mL midpoint of the 25-30 mL final top-up range (E3)'),
  ('HEC', 1.5, 'Must be pre-dispersed in Propylene Glycol before adding to water'),
  ('Propylene Glycol (99.5%)', 30.0, 'Combines 20 mL for HEC slurry (A2a) + 10 mL remainder (A2b)'),
  ('Glycerin (99.5%)', 35.0, null),
  ('Polyquaternium-7 (50% active)', 15.0, null),
  ('GHPTC', 3.0, 'Pre-disperse in warm water first'),
  ('Sodium Gluconate', 2.0, 'Electrolyte — never exceed this ratio (cloud-point risk)'),
  ('C8/C10 APG', 25.0, null),
  ('Sodium Benzoate', 2.0, 'Electrolyte — never exceed this ratio (cloud-point risk)'),
  ('Isopropyl Alcohol (IPA) (90%)', 20.0, 'Flammable — added last in Phase A, keep vessel covered'),
  ('PEG-40 Hydrogenated Castor Oil', 55.0, 'Primary emulsifier — weigh exactly'),
  ('Polysorbate 20 (Tween 20)', 10.0, 'Must be PS-20, not PS-80'),
  ('Amino Silicone Emulsion', 220.0, 'Confirm active % before use'),
  ('Dimethicone 100–350 cSt', 15.0, 'SOP specifies 200-350 cSt — same substance family as stocked'),
  ('Coco Glucoside (APG)', 50.0, null),
  ('CAPB', 20.0, null),
  ('BHT (10% solution in PG)', 0.5, 'Added in the Phase B pre-blend, not Phase C'),
  ('Phenoxyethanol (97-99%)', 8.0, null),
  ('Ethylhexylglycerin (99%)', 2.0, null),
  ('Citric Acid (anhydrous)', 1.0, 'q.s. to pH 5.5-6.0, add dropwise — SOP range was 1-3 mL of 50% solution (0.5-1.5 g anhydrous), this is the midpoint. Record actual amount used per batch'),
  ('Fragrance (water-soluble)', 2.0, null),
  ('Colorant', 1.0, 'Avoid oil-dispersible colorants')
) as v(cname, qty, note) on true
join chemicals c on c.name = v.cname
where f.name = 'Waterless Car Wash — Master Formula (Rev 5.0)'
on conflict do nothing;
