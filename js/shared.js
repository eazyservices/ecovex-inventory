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
// Call renderNav('stock') at the top of each page's <body>, passing the
// current page's key so it highlights correctly.

const NAV_LINKS = [
  { key: 'stock', label: 'Stock', href: 'index.html' },
  { key: 'purchase', label: 'Log Purchase', href: 'pages/purchase.html' },
  { key: 'items', label: 'Manage Items', href: 'pages/items.html' },
  { key: 'issue', label: 'Issue Kit', href: 'pages/issue.html' },
  { key: 'returns', label: 'Returns', href: 'pages/returns.html' },
  { key: 'templates', label: 'Kit Templates', href: 'pages/templates.html' },
  { key: 'employees', label: 'Employees', href: 'pages/employees.html' },
  { key: 'history', label: 'History', href: 'pages/history.html' },
  { key: 'chemicals', label: 'Chemicals', href: 'pages/chemicals.html' },
  { key: 'formulas', label: 'Formulas', href: 'pages/formulas.html' },
];

function renderNav(activeKey, location) {
  // location: 'root' when called from index.html, 'pages' when called from /pages/*.html
  const nav = document.getElementById('nav');
  if (!nav) return;
  nav.innerHTML = NAV_LINKS.map(link => {
    let href = link.href; // defined relative to repo root, e.g. 'pages/purchase.html' or 'index.html'
    if (location === 'pages') {
      href = href === 'index.html' ? '../index.html' : href.replace('pages/', '');
    }
    const cls = link.key === activeKey ? 'tab active' : 'tab';
    return `<a class="${cls}" href="${href}">${link.label}</a>`;
  }).join('');
}
