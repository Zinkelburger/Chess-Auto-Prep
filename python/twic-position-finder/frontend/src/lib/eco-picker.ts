/** ECO opening picker: a searchable modal over /eco.json. */
import { renderBoard } from './board-preview';

/** [code, name, pgn, fen] */
type EcoEntry = [string, string, string, string];

let ecoData: EcoEntry[] = [];
let ecoLoading: Promise<void> | null = null;
/** True once a load finished, successfully or not — an empty list is an answer. */
let ecoSettled = false;

export function loadEcoData(): Promise<void> {
  if (ecoLoading) return ecoLoading;
  ecoLoading = fetch('/eco.json')
    // Not `r.ok ? … : []` — a 404 from a bad deploy has to reject, or the
    // resolved promise below is cached forever and no reopen ever re-fetches.
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`eco.json: ${r.status}`))))
    .then((d: unknown) => {
      if (Array.isArray(d)) ecoData = d as EcoEntry[];
      ecoSettled = true;
    })
    .catch(() => {
      ecoLoading = null; // allow a retry on the next open
    });
  return ecoLoading;
}

function matches(entry: EcoEntry, words: string[]): boolean {
  const haystack = `${entry[0]} ${entry[1]}`.toLowerCase();
  return words.every((w) => haystack.includes(w));
}

const PAGE = 100;

export function openEcoModal(targetInput: HTMLInputElement): void {
  const backdrop = document.createElement('div');
  backdrop.className = 'modal-backdrop';

  const modal = document.createElement('div');
  modal.className = 'modal eco-modal';
  modal.setAttribute('role', 'dialog');
  modal.setAttribute('aria-modal', 'true');
  modal.setAttribute('aria-labelledby', 'eco-modal-title');
  modal.innerHTML = `
    <div class="modal-header">
      <h3 id="eco-modal-title">Choose an opening</h3>
      <button class="modal-close" type="button" aria-label="Close">&times;</button>
    </div>
    <div class="eco-modal-search">
      <input type="search" placeholder="Code or name — B90, Sicilian, Najdorf…" autocomplete="off" aria-label="Search openings" />
    </div>
    <div class="eco-modal-list scroll-thin" role="listbox"></div>
    <div class="modal-footer">
      <span class="eco-selected-count dim"></span>
      <div class="btn-row" style="margin:0">
        <button type="button" class="btn btn-outline btn-sm eco-modal-cancel">Cancel</button>
        <button type="button" class="btn btn-primary btn-sm eco-modal-confirm">Use opening</button>
      </div>
    </div>
  `;
  backdrop.appendChild(modal);
  document.body.appendChild(backdrop);

  const searchInput = modal.querySelector<HTMLInputElement>('.eco-modal-search input')!;
  const listEl = modal.querySelector<HTMLElement>('.eco-modal-list')!;
  const countEl = modal.querySelector<HTMLElement>('.eco-selected-count')!;
  const confirmBtn = modal.querySelector<HTMLButtonElement>('.eco-modal-confirm')!;
  let selectedCode = targetInput.value.trim().toUpperCase();
  const previouslyFocused = document.activeElement as HTMLElement | null;

  function close(): void {
    backdrop.remove();
    document.removeEventListener('keydown', onKey);
    previouslyFocused?.focus();
  }
  function onKey(e: KeyboardEvent): void {
    if (e.key === 'Escape') close();
  }
  document.addEventListener('keydown', onKey);
  modal.querySelector('.modal-close')!.addEventListener('click', close);
  modal.querySelector('.eco-modal-cancel')!.addEventListener('click', close);
  backdrop.addEventListener('click', (e) => {
    if (e.target === backdrop) close();
  });
  confirmBtn.addEventListener('click', () => {
    if (selectedCode) {
      targetInput.value = selectedCode;
      targetInput.dispatchEvent(new Event('input'));
    }
    close();
  });

  function updateCount(): void {
    countEl.textContent = selectedCode ? `Selected: ${selectedCode}` : '';
    confirmBtn.disabled = !selectedCode;
  }

  function renderList(query: string): void {
    listEl.replaceChildren();
    if (ecoData.length === 0) {
      const msg = document.createElement('div');
      msg.className = 'eco-no-results';
      msg.textContent = ecoSettled || !ecoLoading ? 'Opening list unavailable.' : 'Loading openings…';
      listEl.appendChild(msg);
      return;
    }
    const words = query.toLowerCase().split(/\s+/).filter(Boolean);
    const all = words.length ? ecoData.filter((e) => matches(e, words)) : ecoData;
    const shown = all.slice(0, PAGE);

    if (shown.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'eco-no-results';
      empty.textContent = 'No openings match your search';
      listEl.appendChild(empty);
      return;
    }

    const frag = document.createDocumentFragment();
    for (const [code, name, pgn, fen] of shown) {
      const item = document.createElement('div');
      item.className = 'eco-item' + (code === selectedCode ? ' selected' : '');
      item.setAttribute('role', 'option');
      item.setAttribute('aria-selected', String(code === selectedCode));

      const mainRow = document.createElement('button');
      mainRow.type = 'button';
      mainRow.className = 'eco-item-main';
      mainRow.innerHTML = `
        <span class="eco-item-toggle" aria-hidden="true">▸</span>
        <span class="eco-item-code mono"></span>
        <span class="eco-item-name"></span>
        <span class="eco-item-check" aria-hidden="true">✓</span>`;
      mainRow.querySelector('.eco-item-code')!.textContent = code;
      mainRow.querySelector('.eco-item-name')!.textContent = name;

      const details = document.createElement('div');
      details.className = 'eco-item-details';
      details.hidden = true;
      const moves = document.createElement('div');
      moves.className = 'eco-item-moves mono';
      moves.textContent = pgn;
      const boardEl = document.createElement('div');
      boardEl.className = 'board-preview board-preview-sm';
      const lichess = document.createElement('a');
      lichess.href = `https://lichess.org/analysis/pgn/${encodeURIComponent(pgn)}`;
      lichess.target = '_blank';
      lichess.rel = 'noopener';
      lichess.className = 'link-ext';
      lichess.textContent = 'Analyse on Lichess ↗';
      details.append(moves, boardEl, lichess);
      item.append(mainRow, details);

      mainRow.addEventListener('click', () => {
        selectedCode = code;
        listEl.querySelectorAll('.eco-item.selected').forEach((el) => {
          el.classList.remove('selected');
          el.setAttribute('aria-selected', 'false');
        });
        item.classList.add('selected');
        item.setAttribute('aria-selected', 'true');
        updateCount();
        const expanded = details.hidden;
        details.hidden = !expanded;
        mainRow.querySelector('.eco-item-toggle')!.textContent = expanded ? '▾' : '▸';
        if (expanded && !boardEl.hasChildNodes()) renderBoard(fen, boardEl);
      });
      mainRow.addEventListener('dblclick', () => confirmBtn.click());
      frag.appendChild(item);
    }
    listEl.appendChild(frag);

    if (all.length > PAGE) {
      const more = document.createElement('div');
      more.className = 'eco-no-results';
      more.textContent = `Showing ${PAGE} of ${all.length} — refine your search`;
      listEl.appendChild(more);
    }
  }

  let searchTimer: ReturnType<typeof setTimeout> | undefined;
  searchInput.addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => renderList(searchInput.value.trim()), 120);
  });

  renderList(searchInput.value);
  updateCount();
  void loadEcoData().then(() => renderList(searchInput.value.trim()));
  setTimeout(() => searchInput.focus(), 30);
}
