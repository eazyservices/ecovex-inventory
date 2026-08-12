# Ecovex Inventory

Multi-page version — same idea as your other app's structure (`js/` for shared code, `pages/` for each screen), still zero build step: open any `.html` file straight in a browser, deploy as-is on Vercel.

## Folder structure
```
index.html              → Stock dashboard (home page)
js/config.js             → Supabase URL + key, creates the shared `db` client
js/shared.js             → shared helpers (escapeHtml, todayStr, nav bar) used by every page
css/style.css             → shared styling
pages/purchase.html       → Log Purchase (materials + solutions, with landed cost)
pages/items.html          → Manage Items (add materials/solutions)
pages/issue.html          → Issue Kit (uses templates to auto-fill quantities)
pages/templates.html      → Kit Templates (New Employee Kit, Monthly Refill, or your own)
pages/employees.html      → Employees (add, list, per-person issuance history)
pages/history.html        → Procurement & preparation history with full cost breakdown
schema.sql, migration_v2.sql, migration_v3.sql, migration_v4.sql → run in this order in Supabase SQL Editor
```

Only `index.html` and `js/config.js`/`js/shared.js` are referenced with plain relative paths (`css/style.css`, `js/config.js`) since they sit at the root. Every file inside `pages/` reaches back up with `../` (e.g. `../css/style.css`). If you rename or move folders, those paths need to match.

## Setup
1. **Supabase** — run `schema.sql`, then `migration_v2.sql` through `migration_v8.sql`, in order, in the SQL Editor.
2. **GitHub** — upload the whole folder structure (keep `js/`, `css/`, `pages/`, `assets/` as real folders, not flattened).
3. **Vercel** — import the repo, framework preset **Other**, deploy. No env vars needed (Supabase URL/key live in `js/config.js`).
4. **Logo** — drop your logo file into `assets/` as `logo.png`.

## migration_v8 — bug fix + editable chemical price
- **Fixes a real bug**: logging a Prepared solution with a formula selected failed with `column cs.chemical_id does not exist`. That was a mistake in the v7 trigger SQL — fixed now.
- **Chemical prices are now directly editable.** Manage Chemicals → Edit now has a "Current Price/Unit" field you can update any time, no need to log a fake purchase just to correct a price. Logging a real Purchase (not Opening Stock) still auto-updates this to whatever you just paid, so it stays current on its own too.
- **Formulas page decluttered.** Each formula card now shows a "View Ingredients (N)" button instead of always showing the full ingredient table — click to expand, click again to collapse.

## Chemicals & Formulas (new)
This is a completely separate inventory from Materials/Solutions — raw chemicals only (Amino Silicone Emulsion, EDTA, IPA, etc.), used to prepare your own solutions.

- **Chemicals page** — Stock (with reorder alerts, weighted-average cost per unit), Log Purchase/Opening Stock (with GST + transport cost), Manage Chemicals (add/edit, same inline-edit pattern as Manage Items).
- **Formulas page** — each formula belongs to one solution (Tyre Polish, Glass Cleaner, Body Wash) and lists its ingredients with quantity per batch. **Important limitation:** there's no server here to parse an uploaded Word/Excel file automatically, so "uploading a formula" means typing the ingredient list into a form — same pattern as Kit Templates. I pre-loaded your three existing formulas from your SOP documents so you don't have to redo those.
- **Log Purchase → Solutions Log**, when Type = Prepared: pick the formula, enter litres. The ingredient list and estimated cost preview live at that scale, and on submit, **every ingredient is automatically deducted from Chemicals stock** and the batch's real cost is calculated from what you actually paid for those chemicals (weighted average across all your chemical purchases).
- **Stock dashboard** now also shows Chemicals stock and reorder alerts alongside Materials and Solutions.

**Seed data note:** Chemical opening stock quantities came from your tracker spreadsheet's current stock numbers, and costs from your pricing sheet, matched by name. A few chemicals had no price in your sheet (Sodium Bicarbonate, Colorant, Fragrance, HEC, Carnauba Wax) — those were seeded at ₹0/unit. Go to Chemicals → Log Purchase and log a real purchase for those once you know the cost, so batch costing includes them accurately. Also: **RO/Distilled Water** wasn't tracked in your original sheet (since it's effectively free/unlimited) but is needed for accurate batch costing — I seeded a 20-litre placeholder opening stock at ₹0.025/ml; adjust the quantity if you want it to actually track down over time, or leave it since it's not something you'll realistically run out of.

**Formula matching depends on exact solution names.** The seed migration links formulas to your existing `Tyre Polish`, `Glass Cleaning Solution`, and `Body Wash Solution` entries by name. If you've renamed or deleted any of those in Manage Items before running `migration_v7.sql`, that formula just won't get created — check the Formulas page after running it, and add manually if one's missing.

## What's new in this version
- **Bottle count alongside litres** — the Stock page now shows an "Available (Bottles)" column next to litres, calculated automatically, so a physical shelf count is easy to sanity-check against the system.
- **Edit existing items** — Manage Items now has an Edit button on every material and solution row (name, unit, reorder level, bottle size) — no more Supabase table editor needed for that.
- **Visual refresh** — a proper color system grounded in the Ecovex brand (forest green + clean chalk background), card-styled tables and forms, a logo slot in the header on every page.
- **Litres-first solution entry** — you enter litres, bottles are back-calculated automatically.
- **Full landed cost** — every purchase/prep entry now captures unit cost, GST %, and flat transport cost, auto-totalled.
- **History page** — every materials purchase and every solutions log entry, with date, cost breakdown, supplier/invoice, and your remarks on *why*.
- **Kit Templates** — build named, reusable item lists (e.g. "New Employee Kit," "Monthly Refill") with your own quantities per item.
- **Employees module** — add employee (name, code, phone, location), and see a full per-employee issuance history.

## A few things worth considering next (thinking about this as an inventory manager, not just a developer)
- **Wastage/damage logging** — right now every unit that leaves stock is assumed to be a valid issuance. If something breaks, spills, or expires, there's no way to record that separately from "issued to an employee" — which will quietly corrupt your stock accuracy over time. Worth adding a lightweight "Adjustment" entry type.
- **Shelf-life tracking on prepared solutions** — since these are chemical formulations you're mixing in-house, batches likely have a usable window. Right now there's a batch ref but no expiry date or age-based flag.
- **Reorder quantity, not just reorder alert** — the Stock page tells you *that* something's low, but not *how much* to buy, which usually means eyeballing it. A simple "average monthly consumption" number per item (computed from issuance history, which now exists) could turn into a suggested reorder quantity.
- **No login yet** — anyone with the URL has full read/write, including cost data. Fine for now with a small trusted team; worth revisiting once more people touch this.
- **Physical stock reconciliation** — the system's "available" number is only as good as every entry being logged. A periodic "count what's actually on the shelf and compare" screen catches drift before it becomes a real discrepancy.

Happy to build any of these next — just say which one matters most right now.
