/* BiblioJules front-end glue: Alpine stores + HTMX behaviour. */

document.addEventListener('alpine:init', () => {
  // Theme (dark mode) persisted in localStorage.
  Alpine.store('theme', {
    dark: document.documentElement.classList.contains('dark'),
    set(value) {
      this.dark = value === 'dark';
      document.documentElement.classList.toggle('dark', this.dark);
      localStorage.setItem('theme', this.dark ? 'dark' : 'light');
    },
    toggle() {
      this.set(this.dark ? 'light' : 'dark');
    },
  });

  // Modal + transient error handling.
  const i18n = window.BIBLIO_I18N || {};
  Alpine.store('ui', {
    modalOpen: false,
    modalTitle: i18n.defaultModalTitle || 'Add a book',
    error: null,
    open(title) {
      if (title) this.modalTitle = title;
      this.modalOpen = true;
      document.body.classList.add('overflow-hidden');
      // Give the swapped-in form focus (prefer an explicit marker, e.g. the ISBN
      // field when bulk-adding, otherwise the first usable input).
      requestAnimationFrame(() => {
        const el =
          document.querySelector('#modal-body [data-modal-autofocus]') ||
          document.querySelector('#modal-body input:not([type=hidden]):not([disabled])');
        if (el) el.focus();
      });
    },
    close() {
      this.modalOpen = false;
      document.body.classList.remove('overflow-hidden');
      const body = document.getElementById('modal-body');
      if (body) {
        const loading = (window.BIBLIO_I18N && window.BIBLIO_I18N.loading) || 'Loading…';
        body.innerHTML = '<p class="py-10 text-center text-sm text-slate-400">' + loading + '</p>';
      }
      // If books were added while the form stayed open, the page behind is
      // stale — reload once the modal is dismissed.
      if (window.__libraryDirty) {
        window.__libraryDirty = false;
        window.location.reload();
      }
    },
    notify(message) {
      this.error = message;
      clearTimeout(this._t);
      this._t = setTimeout(() => (this.error = null), 6000);
    },
  });
});

// Attach the CSRF token to every HTMX request; the server checks it on any
// state-changing call. The value is rendered into a <meta> tag by base.html.
document.addEventListener('htmx:configRequest', (event) => {
  const meta = document.querySelector('meta[name="csrf-token"]');
  if (meta && meta.content) {
    event.detail.headers['X-CSRF-Token'] = meta.content;
  }
});

// Open the modal whenever new content is swapped into #modal-body, and keep the
// catalog's hidden sort fields in sync when the results grid is swapped.
document.addEventListener('htmx:afterSwap', (event) => {
  const target = event.detail && event.detail.target;
  if (!target) return;
  if (target.id === 'modal-body') {
    // A fragment can request its own title with data-modal-title="…".
    const titled = target.querySelector('[data-modal-title]');
    if (titled && window.Alpine) {
      Alpine.store('ui').modalTitle = titled.getAttribute('data-modal-title');
    }
    window.Alpine && Alpine.store('ui').open();
  } else if (target.id === 'book-grid') {
    syncCatalogSort();
  }
});

// Header-click sorting is reflected in the URL; mirror it into the filter form's
// hidden fields so changing a filter afterwards keeps the chosen order.
function syncCatalogSort() {
  const form = document.getElementById('filters');
  if (!form) return;
  const params = new URLSearchParams(window.location.search);
  const sort = form.querySelector('input[name=sort]');
  const dir = form.querySelector('input[name=dir]');
  if (sort) sort.value = params.get('sort') || 'recent';
  if (dir) dir.value = params.get('dir') || '';
}

// A bulk add fired a bookAdded event (HX-Trigger) — the page behind the modal
// is now out of date, so remember to refresh it on close.
document.addEventListener('bookAdded', () => {
  window.__libraryDirty = true;
});

// Surface server errors as a small toast instead of a silent failure.
document.addEventListener('htmx:responseError', (event) => {
  const xhr = event.detail.xhr;
  const template = (window.BIBLIO_I18N && window.BIBLIO_I18N.error) || 'Something went wrong (%s).';
  let message = template.replace('%s', xhr.status);
  try {
    const data = JSON.parse(xhr.responseText);
    if (data && data.detail) message = data.detail;
  } catch (e) { /* not JSON, keep default */ }
  window.Alpine && Alpine.store('ui').notify(message);
});

// Keep a scan field focused when the page loads so a USB reader "just works".
document.addEventListener('DOMContentLoaded', () => {
  const scan = document.querySelector('[data-autofocus-scan]');
  if (scan && window.matchMedia('(min-width: 640px)').matches) scan.focus();
});
