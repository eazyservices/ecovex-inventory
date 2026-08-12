-- ============================================================
-- ECOVEX INVENTORY — migration v6 (fixed)
-- Run in Supabase SQL editor after v2–v5.
-- Adds an "Opening Stock" entry type for old/existing material and
-- solutions you already had before starting to use this system.
-- ============================================================

-- ---------- Materials: add an entry_type tag ----------

alter table materials_purchases add column if not exists entry_type text not null default 'Purchase';
alter table materials_purchases drop constraint if exists materials_purchases_entry_type_check;
alter table materials_purchases add constraint materials_purchases_entry_type_check
  check (entry_type in ('Purchase', 'Opening Stock'));

-- ---------- Solutions: allow 'Opening Stock' as a log_type ----------

alter table solutions_log drop constraint if exists solutions_log_log_type_check;
alter table solutions_log add constraint solutions_log_log_type_check
  check (log_type in ('Purchased', 'Prepared', 'Opening Stock'));

-- ---------- Refresh history view (drop + recreate, not replace) ----------

drop view if exists materials_purchase_history;

create view materials_purchase_history as
select
  mp.id,
  mp.purchase_date,
  m.name as material_name,
  mp.entry_type,
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
