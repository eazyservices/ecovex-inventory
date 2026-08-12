-- ============================================================
-- ECOVEX INVENTORY — migration v14
-- Run in Supabase SQL editor after Sql/migration_v13.sql.
--
-- Switches Tyre Polish V3's IPA and Silicone Emulsion to the
-- concentrations actually being stocked (90% and 55%, instead of
-- the manual's 99%/60% baseline), recalculating quantities to
-- deliver the same active content rather than just swapping the
-- chemical. Also clarifies that the fragrance ingredient is
-- oil-based, not water-soluble.
-- ============================================================

-- ---------- 1. New chemical: Silicone Emulsion (55% active) ----------
-- Genuinely different spec from the existing 60% active chemical,
-- same pattern as every other concentration variant so far.

insert into chemicals (name, alt_name, unit, reorder_level) values
  ('Silicone Emulsion (55% active)', null, 'g', 275)
on conflict (name) do nothing;

-- ---------- 2. Clarify the fragrance is oil-based ----------
-- There's a separate 'Fragrance (water-soluble)' chemical used in
-- other formulas — flagging this explicitly so purchasing/logging
-- doesn't mix the two up.

update chemicals
set alt_name = 'Oil-based — do not substitute with water-soluble fragrance'
where name = 'Fragrance Oil (Lemon or Tea Tree)';

-- ---------- 3. Recalculate Tyre Polish V3's Phase B/D/E ingredients ----------
-- IPA: 30.0 g/L of 99% = 29.7 g/L pure isopropanol. At 90% strength,
-- 33.0 g/L delivers the same 29.7 g/L active content.
-- Silicone Emulsion: your manual's own section 04 table gives the
-- 55%-active dose directly — 272.7 g/L (up from 250.0 g/L), with the
-- difference meant to come out of the RO Water top-up.
-- RO Water: recomputed as the remainder to keep the batch at exactly
-- 1000 g/L given both changes above (this also folds in a small 2.5g
-- drift left over from retiring 'Citric Acid (50% solution)' in v13,
-- which hadn't been re-balanced into the water figure until now).

update formula_ingredients fi
set chemical_id = (select id from chemicals where name = 'Isopropyl Alcohol (IPA) (90%)'),
    qty_per_batch = 33.0,
    notes = 'Switched from 99% to 90% IPA (actually stocked) — dosed to the same 29.7 g/L pure isopropanol content as the original 30.0 g/L @ 99%'
where fi.chemical_id = (select id from chemicals where name = 'Isopropyl Alcohol (IPA 99%)')
  and fi.formula_id = (select id from formulas where name = 'Tyre Polish — V3 (Rev 3.0)');

update formula_ingredients fi
set chemical_id = (select id from chemicals where name = 'Silicone Emulsion (55% active)'),
    qty_per_batch = 272.7,
    notes = 'Switched from 60% to 55% active (actually stocked) — dose per the manual''s own section 04 adjustment table (150 g active ÷ 0.55)'
where fi.chemical_id = (select id from chemicals where name = 'Silicone Emulsion (60% active)')
  and fi.formula_id = (select id from formulas where name = 'Tyre Polish — V3 (Rev 3.0)');

update formula_ingredients fi
set qty_per_batch = 447.3,
    notes = 'Recomputed remainder to reach exactly 1000 g/L total, given the 90% IPA and 55% Silicone Emulsion doses above (was 470.5 g/L combining the manual''s 430 g start charge + 40.5 g top-up)'
where fi.chemical_id = (select id from chemicals where name = 'RO / Distilled Water')
  and fi.formula_id = (select id from formulas where name = 'Tyre Polish — V3 (Rev 3.0)');
