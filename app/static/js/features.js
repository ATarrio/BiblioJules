/* BiblioJules personal features: reading stats, goals and want-to-read list.
   Talks to the JSON API endpoints introduced with the personal-stat work.

   Uses window.BIBLIO_I18N.strings[key] for all human-facing text, falling back
   to the English source string (which is what you see in the template calls to
   _('…')).  This single source of truth replaces every earlier ad-hoc fallback. */

(function () {
  'use strict';

  const i18n = window.BIBLIO_I18N || {};
  const STRINGS = i18n.strings || {};

  /** Translate a source English string, falling back to the string itself. */
  const t = (key) => {
    return STRINGS[key] || key;
  };

  /** Escape HTML for safe interpolation. */
  function escapeHtml(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  /** Headers for a same-origin JSON write, including the session's CSRF token. */
  function writeHeaders() {
    const meta = document.querySelector('meta[name="csrf-token"]');
    const headers = { 'Content-Type': 'application/json' };
    if (meta && meta.content) headers['X-CSRF-Token'] = meta.content;
    return headers;
  }

  /** The same, for a body-less DELETE. */
  function writeHeadersNoBody() {
    const meta = document.querySelector('meta[name="csrf-token"]');
    return meta && meta.content ? { 'X-CSRF-Token': meta.content } : {};
  }

  /** Plural-aware helper built on BIBLIO_I18N.plural(singular, n). */
  function np(singular, n) {
    const fn = i18n.plural;
    if (typeof fn === 'function') return fn(singular, n);
    return n === 1 ? singular : singular + 's';
  }

  // ----------------------------------------------------------------------- #
  // Stats formatting (used by the dashboard widget and the reading page)
  // ----------------------------------------------------------------------- #
  const formatStats = (s) => {
    if (!s || !s.books_read) return t('—');
    const parts = [];
    if (s.books_read)        parts.push(`${s.books_read} ${t('📖')}`);
    if (s.pages_read)       parts.push(`${s.pages_read.toLocaleString()} ${t('📄')}`);
    if (s.avg_rating)        parts.push(`${s.avg_rating} ${t('⭐')}`);
    return parts.join(' · ');
  };

  // ----------------------------------------------------------------------- #
  // Reading stats widget (dashboard only — the reading page fetches & fills
  // its own stat cards)
  // ----------------------------------------------------------------------- #
  async function fetchStatsData() {
    try {
      const res = await fetch('/api/personal-stats');
      if (!res.ok) return null;
      return await res.json();
    } catch (e) { return null; }
  }

  function bindStatsWidget(host) {
    if (!host) return;
    (async () => {
      const stats = await fetchStatsData();
      if (stats) host.textContent = formatStats(stats);
    })();
  }
  // ----------------------------------------------------------------------- #
  // Reading goals
  // ----------------------------------------------------------------------- #
  async function loadGoals() {
    try {
      const res = await fetch('/api/goals');
      if (!res.ok) return null;
      return await res.json();
    } catch (e) { return null; }
  }

  async function saveGoals(goals) {
    try {
      const res = await fetch('/api/goals', {
        method: 'POST',
        headers: writeHeaders(),
        body: JSON.stringify(goals),
      });
      return res.ok;
    } catch (e) { return false; }
  }

  /** Update the goals progress bars. `stats` carries live books/pages read. */
  function renderGoalsProgress(goals, stats, host) {
    if (!host || !goals) return;
    const booksDone = stats?.books_read || 0;
    const pagesDone = stats?.pages_read || 0;
    const bookTarget = goals.target_books || 0;
    const pageTarget = goals.target_pages || 0;
    const bar = (done, target) => ({
      pct: target ? Math.min(100, Math.round((done / target) * 100)) : 0,
      label: target ? `${done}/${target}` : `${done}`,
    });
    const books = bar(booksDone, bookTarget);
    const pages = bar(pagesDone, pageTarget);

    host.innerHTML = '';
    host.insertAdjacentHTML('beforeend',
      `<div class="space-y-3">` +
      `<div class="space-y-2">` +
      `<div class="flex items-center justify-between text-sm">` +
        `<span class="text-slate-600 dark:text-slate-400">${t('Reading goal')}</span>` +
        `<span class="font-medium text-slate-900 dark:text-white">${books.label} ${t('books')}</span>` +
      `</div>` +
      `<div class="h-2 w-full rounded-full bg-slate-200 dark:bg-slate-700">` +
        `<div class="h-full rounded-full bg-brand-600 transition-all" style="width:${books.pct}%"></div>` +
      `</div>` +
      `</div>` +
      (pageTarget ?
        `<div class="space-y-2">` +
        `<div class="flex items-center justify-between text-sm">` +
          `<span class="text-slate-600 dark:text-slate-400">${t('Pages goal')}</span>` +
          `<span class="font-medium text-slate-900 dark:text-white">${pages.label} ${t('pages')}</span>` +
        `</div>` +
        `<div class="h-2 w-full rounded-full bg-slate-200 dark:bg-slate-700">` +
          `<div class="h-full rounded-full bg-emerald-500 transition-all" style="width:${pages.pct}%"></div>` +
        `</div>` +
        `</div>` : '') +
      `</div>`
    );
  }

  // ----------------------------------------------------------------------- #
  // Want-to-read list
  // ----------------------------------------------------------------------- #
  async function loadWantlist() {
    try {
      const res = await fetch('/api/wantlist');
      if (!res.ok) return [];
      return await res.json();
    } catch (e) { return []; }
  }

  async function removeWantEntry(entry) {
    const id = entry.id || entry.isbn || entry.title;
    try {
      const res = await fetch(`/api/wantlist/${encodeURIComponent(id)}`, {
        method: 'DELETE',
        headers: writeHeadersNoBody(),
      });
      if (res.ok) return true;
    } catch (e) { /* ignore */ }
    return false;
  }

  function bindWantlist(host) {
    if (!host || host.dataset.wantlistBound === '1') return;
    host.dataset.wantlistBound = '1';
    host.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-want-remove]');
      if (!btn) return;
      const id = btn.getAttribute('data-want-remove');
      (async () => {
        const ok = await removeWantEntry({ id });
        if (ok) {
          const items = await loadWantlist();
          renderWantlist(items, host);
        }
      })();
    });
  }

  function renderWantlist(items, host) {
    if (!host) return;
    bindWantlist(host);
    if (!items.length) {
      host.innerHTML =
        `<div class="text-center py-8 text-slate-500 dark:text-slate-400">` +
        `<div class="text-3xl mb-2">📚</div>` +
        `<p>${t('No books on your want-to-read list yet.')}</p>` +
        `</div>`;
      return;
    }
    host.innerHTML = '';
    items.forEach((item) => {
      const card = document.createElement('div');
      card.className =
        'group flex items-center gap-3 rounded-xl border border-slate-200 bg-card p-3 shadow-sm dark:border-slate-800 dark:bg-slate-900';
      card.innerHTML =
        `<div class="flex-1 min-w-0">` +
          `<div class="font-medium text-slate-900 dark:text-white truncate">${escapeHtml(item.title || '—')}</div>` +
          `<div class="truncate text-xs text-slate-500 dark:text-slate-400">` +
            `${escapeHtml(item.authors || '—')}` +
            `${item.publisher ? ' · ' + escapeHtml(item.publisher) : ''}` +
          `</div>` +
        `</div>` +
        `<button data-want-remove="${escapeHtml(item.id || item.isbn || item.title)}"` +
          ` class="rounded-lg p-1.5 text-slate-400 opacity-0 transition-opacity hover:text-red-500 hover:opacity-100 group-hover:opacity-100"` +
          ` title="${t('Remove from want-to-read')}">` +
          `<svg class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">` +
            `<path stroke-linecap="round" stroke-linejoin="round" d="M19 7l-.867 12.13A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.87L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>` +
          `</svg>` +
        `</button>`;
      host.appendChild(card);
    });
  }

  // ----------------------------------------------------------------------- #
  // Boot — bind to whichever page we are on
  // ----------------------------------------------------------------------- #
  const onReady = () => {
    // Dashboard widget
    bindStatsWidget(document.getElementById('reading-stats-widget'));

    // Reading goals page
    const goalsHost = document.getElementById('reading-goals-host');
    const refreshGoals = async () => {
      const goals = await loadGoals();
      const stats = await fetchStatsData();
      if (goals && goalsHost) {
        renderGoalsProgress(goals, stats, goalsHost);
      }
      return goals;
    };
    refreshGoals();
    // The reading page's form posts the goals itself; this just re-renders.
    window.biblioSaveGoals = refreshGoals;

    // Want-to-read list page
    const wantlistHost = document.getElementById('wantlist-items');
    const loadAndRender = async () => {
      const items = await loadWantlist();
      renderWantlist(items, wantlistHost);
    };
    loadAndRender();
    window.biblioLoadWantlist = loadAndRender;

    // Reading stats page — fill in stat cards
    (async () => {
      try {
        const res = await fetch('/api/personal-stats');
        if (!res.ok) return;
        const s = await res.json();
        const set = (id, v) => {
          const el = document.getElementById(id);
          if (el) el.textContent = (v === null || v === undefined) ? '—' : v;
        };
        set('stats-books-read', s.books_read);
        set('stats-pages-read', s.pages_read);
        set('stats-avg-rating', s.avg_rating ?? '—');
        set('stats-currently-reading', s.currently_reading);
        set('stats-dnf', s.status_breakdown?.dnf);
        set('stats-lost-donated', (s.status_breakdown?.lost || 0) + (s.status_breakdown?.donated || 0));
      } catch (e) { /* ignore */ }
    })();
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', onReady);
  } else {
    onReady();
  }
})();
