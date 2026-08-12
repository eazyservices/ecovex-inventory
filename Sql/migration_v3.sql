-- ============================================================
-- ECOVEX INVENTORY — migration v3
-- Run in Supabase SQL editor AFTER schema.sql and migration_v2.sql.
-- Adds named, reusable kit templates (e.g. "New Employee Kit",
-- "Monthly Refill") each with their own item list + quantities,
-- replacing the single fixed kit_default_qty per item.
-- Safe to re-run.
-- ============================================================

create table if not exists kit_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text,
  created_at timestamptz not null default now()
);

create table if not exists kit_template_items (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references kit_templates(id) on delete cascade,
  category text not null check (category in ('Material', 'Solution')),
  material_id uuid references materials(id),
  solution_id uuid references solutions(id),
  qty numeric not null check (qty > 0),
  check (
    (category = 'Material' and material_id is not null and solution_id is null) or
    (category = 'Solution' and solution_id is not null and material_id is null)
  )
);

alter table kit_templates enable row level security;
alter table kit_template_items enable row level security;

drop policy if exists "Public read/write - kit_templates" on kit_templates;
create policy "Public read/write - kit_templates" on kit_templates for all using (true) with check (true);

drop policy if exists "Public read/write - kit_template_items" on kit_template_items;
create policy "Public read/write - kit_template_items" on kit_template_items for all using (true) with check (true);

-- Convenience view: template items with readable names, for the Issue page
create or replace view kit_template_items_detail as
select
  kti.id,
  kti.template_id,
  kt.name as template_name,
  kti.category,
  coalesce(m.name, s.name) as item_name,
  kti.material_id,
  kti.solution_id,
  kti.qty
from kit_template_items kti
join kit_templates kt on kt.id = kti.template_id
left join materials m on m.id = kti.material_id
left join solutions s on s.id = kti.solution_id
order by kt.name, item_name;

-- Two starter templates so the Issue page isn't empty on first load.
-- Edit or delete these from the Kit Templates page — they're just a starting point.
insert into kit_templates (name, description) values
  ('New Employee Kit', 'Full starter kit given to a new attendant'),
  ('Monthly Refill', 'Typical monthly top-up quantities')
on conflict (name) do nothing;
