-- ============================================================
-- ECOVEX INVENTORY — migration v15
-- Run in Supabase SQL editor after Sql/migration_v14.sql.
--
-- Tyre Polish V3: the Fragrance Oil is now premixed with a reserved
-- portion of Polysorbate 80 before adding to the batch (Phase E),
-- instead of added neat. The existing Phase C Polysorbate 80 line
-- (35 g/L) is fully committed to the emulsifier pre-blend already,
-- so this is tracked as a genuinely separate 4 g/L addition — not
-- folded into the existing row — so stock deduction and the
-- production calculator correctly reflect total Polysorbate 80
-- consumption (39 g/L) against available stock. RO Water top-up is
-- rebalanced to keep the batch at exactly 1000 g/L.
-- ============================================================

-- New reserved Polysorbate 80 portion for the fragrance premix.
insert into formula_ingredients (formula_id, chemical_id, qty_per_batch, notes)
select f.id, c.id, 4.0,
  'Reserved for pre-dissolving the Fragrance Oil (not part of the Phase C emulsifier blend) — whisk the two together in a small dish until one clear, uniform liquid, then add to the batch in Phase E. In addition to the 35 g/L Polysorbate 80 already used in Phase C.'
from formulas f, chemicals c
where f.name = 'Tyre Polish — V3 (Rev 3.0)' and c.name = 'Polysorbate 80 (Tween 80)'
on conflict do nothing;

-- Fragrance Oil no longer added neat — update the note accordingly.
update formula_ingredients fi
set notes = 'Premix with the reserved 4 g/L Polysorbate 80 portion before adding (see that ingredient''s note) — do not add neat.'
where fi.chemical_id = (select id from chemicals where name = 'Fragrance Oil (Lemon or Tea Tree)')
  and fi.formula_id = (select id from formulas where name = 'Tyre Polish — V3 (Rev 3.0)');

-- RO Water top-up rebalanced: 447.3 - 4.0 = 443.3 g/L, keeping the
-- batch at exactly 1000 g/L with the extra Polysorbate 80 added.
update formula_ingredients fi
set qty_per_batch = 443.3,
    notes = 'Recomputed remainder to reach exactly 1000 g/L total, now accounting for the 4 g/L Polysorbate 80 reserved for the fragrance premix (was 447.3 g/L)'
where fi.chemical_id = (select id from chemicals where name = 'RO / Distilled Water')
  and fi.formula_id = (select id from formulas where name = 'Tyre Polish — V3 (Rev 3.0)');
