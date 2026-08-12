// ---------- small utilities used on every page ----------

function todayStr() {
  return new Date().toISOString().slice(0, 10);
}

function escapeHtml(str) {
  return String(str ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function showMsg(el, type, text) {
  el.innerHTML = `<div class="msg ${type}">${escapeHtml(text)}</div>`;
}

// ---------- shared top navigation ----------
// Two groups — Material (stock you buy & issue) and Manufacturing (chemicals
// and the solutions you prepare in-house from them). Call
// renderNav(activeKey, location, group) at the top of each page's <body>,
// where location is 'root' from index.html or 'pages' from /pages/*.html,
// and group is 'material' or 'manufacturing'.

const NAV_MATERIAL = [
  { key: 'material-stock', label: 'Stock', href: 'pages/material.html' },
  { key: 'purchase', label: 'Log Purchase', href: 'pages/purchase.html' },
  { key: 'items', label: 'Manage Items', href: 'pages/items.html' },
  { key: 'issue', label: 'Issue Kit', href: 'pages/issue.html' },
  { key: 'returns', label: 'Returns', href: 'pages/returns.html' },
  { key: 'templates', label: 'Kit Templates', href: 'pages/templates.html' },
  { key: 'employees', label: 'Employees', href: 'pages/employees.html' },
  { key: 'history', label: 'History', href: 'pages/history.html' },
];

const NAV_MANUFACTURING = [
  { key: 'manufacturing-stock', label: 'Stock', href: 'pages/manufacturing.html' },
  { key: 'chemicals', label: 'Chemicals', href: 'pages/chemicals.html' },
  { key: 'formulas', label: 'Formulas', href: 'pages/formulas.html' },
  { key: 'history', label: 'History', href: 'pages/history.html' },
];

function renderNav(activeKey, location, group) {
  const nav = document.getElementById('nav');
  if (!nav) return;

  const prefix = location === 'pages' ? '../' : '';
  const links = group === 'manufacturing' ? NAV_MANUFACTURING : NAV_MATERIAL;

  const homeLink = `<a class="tab" href="${prefix}index.html">🏠 Home</a>`;

  const materialHref = location === 'pages' ? 'material.html' : 'pages/material.html';
  const manufacturingHref = location === 'pages' ? 'manufacturing.html' : 'pages/manufacturing.html';
  const switcher = `
    <a class="tab switcher ${group === 'material' ? 'active' : ''}" href="${materialHref}">🧰 Material</a>
    <a class="tab switcher ${group === 'manufacturing' ? 'active' : ''}" href="${manufacturingHref}">🧪 Manufacturing</a>
    <span class="nav-sep"></span>
  `;

  const groupLinks = links.map(link => {
    const href = location === 'pages' ? link.href.replace('pages/', '') : link.href;
    const cls = link.key === activeKey ? 'tab active' : 'tab';
    return `<a class="${cls}" href="${href}">${link.label}</a>`;
  }).join('');

  nav.innerHTML = homeLink + switcher + groupLinks;
}
