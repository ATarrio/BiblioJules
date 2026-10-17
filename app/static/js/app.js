/* BiblioJules front-end glue: Alpine stores + HTMX behaviour. */

document.addEventListener('alpine:init', () => {
  // Theme (dark mode) persisted in localStorage.
  Alpine.store('theme', {
    dark: document.documentElement.classList.contains('dark'),
    toggle() {
      this.dark = !this.dark;
      document.documentElement.classList.toggle('dark', this.dark);
      localStorage.setItem('theme', this.dark ? 'dark' : 'light');
    },
  });

  // Modal + transient error handling.
  Alpine.store('ui', {
    modalOpen: false,
    modalTitle: 'Add a book',
    error: null,
    open(title) {
      if (title) this.modalTitle = title;
      this.modalOpen = true;
      document.body.classList.add('overflow-hidden');
      // Give the swapped-in form focus (except for select buttons).
      requestAnimationFrame(() => {
        const el = document.querySelector('#modal-body input:not([type=hidden]):not([disabled])');
        if (el) el.focus();
      });
    },
    close() {
      this.modalOpen = false;
      document.body.classList.remove('overflow-hidden');
      const body = document.getElementById('modal-body');
      if (body) body.innerHTML = '<p class="py-10 text-center text-sm text-slate-400">Loading…</p>';
    },
    notify(message) {
      this.error = message;
      clearTimeout(this._t);
      this._t = setTimeout(() => (this.error = null), 6000);
    },
  });
});

// Open the modal whenever new content is swapped into #modal-body.
document.addEventListener('htmx:afterSwap', (event) => {
  const target = event.detail && event.detail.target;
  if (target && target.id === 'modal-body') {
    // A fragment can request its own title with data-modal-title="…".
    const titled = target.querySelector('[data-modal-title]');
    if (titled && window.Alpine) {
      Alpine.store('ui').modalTitle = titled.getAttribute('data-modal-title');
    }
    window.Alpine && Alpine.store('ui').open();
  }
});

// Surface server errors as a small toast instead of a silent failure.
document.addEventListener('htmx:responseError', (event) => {
  const xhr = event.detail.xhr;
  let message = `Something went wrong (${xhr.status}).`;
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
