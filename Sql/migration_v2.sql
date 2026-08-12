-- ============================================================
-- ECOVEX INVENTORY — migration v2
-- Run this in the Supabase SQL editor AFTER the original schema.sql.
-- Safe to re-run (uses IF NOT EXISTS / IF EXISTS everywhere).
-- ============================================================

-- ---------- 1. FIX RLS LOCKOUT ----------
-- The original policies only allowed role = 'authenticated'. This app
-- has no login screen, so every request runs as 'anon' and was being
-- silently blocked — that's why the dropdowns showed no items.
-- Since there's no auth yet, open access to anon as well.

drop policy if exists "Authenticated read/write - materials" on materials;
drop policy if exists "Authenticated read/write - solutions" on solutions;
drop policy if exists "Authenticated read/write - attendants" on attendants;
drop policy if exists "Authenticated read/write - materials_purchases" on materials_purchases;
drop policy if exists "Authenticated read/write - solutions_log" on solutions_log;
drop policy if exists "Authenticated read/write - issuance_log" on issuance_log;

create policy "Public read/write - materials" on materials for all using (true) with check (true);
create policy "Public read/write - solutions" on solutions for all using (true) with check (true);
create policy "Public read/write - attendants" on attendants for all using (true) with check (true);
create policy "Public read/write - materials_purchases" on materials_purchases for all using (true) with check (true);
create policy "Public read/write - solutions_log" on solutions_log for all using (true) with check (true);
create policy "Public read/write - issuance_log" on issuance_log for all using (true) with check (true);

-- ---------- 2. EMPLOYEE (ATTENDANT) DETAILS ----------

alter table attendants add column if not exists code text;
alter table attendants add column if not exists phone text;
alter table attendants add column if not exists location text;
alter table attendants add column if not exists joined_date date default current_date;

create unique index if not exists attendants_code_key on attendants(code) where code is not null;

-- ---------- 3. LINK ISSUANCE LOG TO A REAL EMPLOYEE RECORD ----------
-- Keeps the old free-text "attendant" column so nothing breaks, but
-- adds attendant_id so you can pull a clean per-employee history.

alter table issuance_log add column if not exists attendant_id uuid references attendants(id);

create or replace function fn_issuance_attendant_name()
returns trigger language plpgsql as $$
begin
  if new.attendant_id is not null then
    select a.name into new.attendant from attendants a where a.id = new.attendant_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_issuance_attendant_name on issuance_log;
create trigger trg_issuance_attendant_name
  before insert or update on issuance_log
  for each row execute function fn_issuance_attendant_name();

-- ---------- 4. "COMPLETE KIT" DEFAULT QUANTITIES ----------
-- Set these once in the table editor to match your actual starter kit
-- (e.g. Microfiber Clothes = 10, Dusting Brush – Regular = 2, etc).
-- The Issue Kit screen's "Fill Complete Kit" button uses these.

alter table materials add column if not exists kit_default_qty numeric not null default 0;
alter table solutions add column if not exists kit_default_qty numeric not null default 0;

-- ---------- 5. Per-employee issuance history view ----------

create or replace view employee_issuance_history as
select
  il.id,
  il.attendant_id,
  a.name as attendant_name,
  a.code as attendant_code,
  il.issue_date,
  il.category,
  coalesce(m.name, s.name) as item_name,
  il.qty_issued,
  il.litres_issued,
  il.issued_by,
  il.remarks,
  il.created_at
from issuance_log il
left join attendants a on a.id = il.attendant_id
left join materials m on m.id = il.material_id
left join solutions s on s.id = il.solution_id
order by il.issue_date desc, il.created_at desc;
