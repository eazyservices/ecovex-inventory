-- ============================================================
-- ECOVEX INVENTORY — migration v16
-- Run in Supabase SQL editor after Sql/migration_v15.sql.
--
-- Waterless Car Wash — Master Formula (Rev 5.0): the fragrance was
-- mis-tracked as the water-soluble fragrance chemical when it's
-- actually oil-based (matches the SOP's own confusing "Citric
-- Fragrance (water-soluble)" label — it's oil-based, not
-- water-soluble). Switches it to the existing oil-based fragrance
-- chemical and adds a reserved Polysorbate 20 portion to premix it
-- with, same reasoning as the Tyre Polish V3 change: Phase B's
-- Polysorbate 20 (10 mL/L) is already fully committed to that
-- phase's pre-blend by the time fragrance goes in at Phase E, so a
-- separate premix portion is needed rather than reusing it.
--
-- NOTE: assumes the fragrance oil in use is the same product as
-- Tyre Polish's 'Fragrance Oil (Lemon or Tea Tree)' — if this
-- formula actually uses a different scent, let me know and I'll
-- split it into its own chemical.
-- ============================================================

-- Switch the fragrance ingredient to the oil-based chemical.
update formula_ingredients fi
set chemical_id = (select id from chemicals where name = 'Fragrance Oil (Lemon or Tea Tree)'),
    notes = 'Oil-based, not water-soluble (the SOP''s "Citric Fragrance (water-soluble)" label was wrong). Premix with the reserved 4 mL/L Polysorbate 20 portion before adding — do not add neat.'
where fi.chemical_id = (select id from chemicals where name = 'Fragrance (water-soluble)')
  and fi.formula_id = (select id from formulas where name = 'Waterless Car Wash — Master Formula (Rev 5.0)');

-- New reserved Polysorbate 20 portion for the fragrance premix —
-- tracked as its own row (not folded into the existing 10 mL/L
-- Phase B line) so stock deduction and the production capacity
-- calculator reflect true total consumption (14 mL/L) correctly.
insert into formula_ingredients (formula_id, chemical_id, qty_per_batch, notes)
select f.id, c.id, 4.0,
  'Reserved for pre-dissolving the Fragrance Oil (not part of the Phase B pre-blend) — whisk the two together in a small dish until one clear, uniform liquid, then add to the batch in Phase E/Step 10. In addition to the 10 mL/L Polysorbate 20 already used in Phase B.'
from formulas f, chemicals c
where f.name = 'Waterless Car Wash — Master Formula (Rev 5.0)' and c.name = 'Polysorbate 20 (Tween 20)'
on conflict do nothing;
