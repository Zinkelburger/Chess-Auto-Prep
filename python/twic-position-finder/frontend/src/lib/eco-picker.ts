import { previewBoard } from './api';

type EcoEntry = [string, string, string, string];

let ecoData: EcoEntry[] = [];
let ecoLoaded = false;

export async function loadEcoData(): Promise<void> {
  if (ecoLoaded) return;
  try {
    const res = await fetch('/eco.json');
    ecoData = await res.json();
    ecoLoaded = true;
  } catch {
    /* picker still opens; list stays empty */
  }
}

function fuzzyMatch(entry: EcoEntry, query: string): boolean {
  const [code, name] = entry;
  const words = query.toLowerCase().split(/\s+/).filter((w) => w.length > 0);
  const haystack = `${code} ${name}`.toLowerCase();
  return words.every((w) => haystack.includes(w));
}

function lichessAnalysisUrl(pgn: string): string {
  return `https://lichess.org/analysis/pgn/${encodeURIComponent(pgn)}`;
}

export function openEcoModal(targetInput: HTMLInputElement): void {
  void loadEcoData();

  const backdrop = document.createElement('div');
  backdrop.className = 'eco-modal-backdrop';

  const modal = document.createElement('div');
  modal.className = 'eco-modal';
  modal.setAttribute('role', 'dialog');
  modal.setAttribute('aria-modal', 'true');
  modal.setAttribute('aria-label', 'Select ECO opening');
  modal.innerHTML = `
    <div class="eco-modal-header">
      <h3>Select opening</h3>
      <button class="eco-modal-close" type="button" aria-label="Close">&times;</button>
    </div>
    <div class="eco-modal-search">
      <input type="search" placeholder="Search by code or name — B90, Sicilian, Najdorf" autocomplete="off" />
      <p class="eco-search-hint">Type to filter 3,300+ openings. Click a row, then Select.</p>
    </div>
    <div class="eco-modal-list"></div>
    <div class="eco-modal-footer">
      <span class="eco-selected-count"></span>
      <div class="eco-modal-actions">
        <button type="button" class="btn btn-outline btn-sm eco-modal-cancel">Cancel</button>
        <button type="button" class="btn btn-primary btn-sm eco-modal-confirm">Select</button>
      </div>
    </div>
  `;

  backdrop.appendChild(modal);
  document.body.appendChild(backdrop);

  const searchInput = modal.querySelector('.eco-modal-search input') as HTMLInputElement;
  const listEl = modal.querySelector('.eco-modal-list')!;
  const countEl = modal.querySelector('.eco-selected-count')!;
  let selectedCode = targetInput.value.trim().toUpperCase();

  function onKey(e: KeyboardEvent) {
    if (e.key === 'Escape') close();
  }

  function close() {
    backdrop.remove();
    document.removeEventListener('keydown', onKey);
  }

  modal.querySelector('.eco-modal-close')!.addEventListener('click', close);
  modal.querySelector('.eco-modal-cancel')!.addEventListener('click', close);
  backdrop.addEventListener('click', (e) => {
    if (e.target === backdrop) close();
  });
  document.addEventListener('keydown', onKey);

  modal.querySelector('.eco-modal-confirm')!.addEventListener('click', () => {
    if (selectedCode) {
      targetInput.value = selectedCode;
      targetInput.dispatchEvent(new Event('input'));
    }
    close();
  });

  function renderList(query: string) {
    const filtered = query
      ? ecoData.filter((e) => fuzzyMatch(e, query)).slice(0, 100)
      : ecoData.slice(0, 100);

    if (filtered.length === 0) {
      listEl.textContent = '';
      const empty = document.createElement('div');
      empty.className = 'eco-no-results';
      empty.textContent = 'No openings match your search';
      listEl.appendChild(empty);
      return;
    }

    listEl.replaceChildren();
    const frag = document.createDocumentFragment();

    for (const [code, name, pgn, fen] of filtered) {
      const item = document.createElement('div');
      item.className = 'eco-item' + (code === selectedCode ? ' selected' : '');

      const mainRow = document.createElement('div');
      mainRow.className = 'eco-item-main';

      const toggle = document.createElement('span');
      toggle.className = 'eco-item-toggle';
      toggle.textContent = '▸';

      const codeEl = document.createElement('span');
      codeEl.className = 'eco-item-code';
      codeEl.textContent = code;

      const nameEl = document.createElement('span');
      nameEl.className = 'eco-item-name';
      nameEl.textContent = name;

      const check = document.createElement('span');
      check.className = 'eco-item-check';
      check.textContent = '✓';

      mainRow.append(toggle, codeEl, nameEl, check);

      const details = document.createElement('div');
      details.className = 'eco-item-details';

      const moves = document.createElement('div');
      moves.className = 'eco-item-moves';
      moves.textContent = pgn;

      const boardEl = document.createElement('div');
      boardEl.className = 'eco-item-board';

      const lichess = document.createElement('a');
      lichess.href = lichessAnalysisUrl(pgn);
      lichess.target = '_blank';
      lichess.rel = 'noopener';
      lichess.className = 'eco-lichess-btn';
      lichess.textContent = 'Analyze on Lichess ↗';

      details.append(moves, boardEl, lichess);
      item.append(mainRow, details);

      mainRow.addEventListener('click', () => {
        selectedCode = code;
        listEl.querySelectorAll('.eco-item.selected').forEach((el) => el.classList.remove('selected'));
        item.classList.add('selected');
        updateCount();
        const expanded = item.classList.toggle('expanded');
        toggle.textContent = expanded ? '▾' : '▸';
        if (expanded && !boardEl.hasChildNodes()) {
          previewBoard(fen, boardEl, null);
          boardEl.style.display = 'grid';
        }
      });

      frag.appendChild(item);
    }

    listEl.appendChild(frag);

    const total = query ? ecoData.filter((e) => fuzzyMatch(e, query)).length : ecoData.length;
    if (total > 100) {
      const more = document.createElement('div');
      more.className = 'eco-no-results';
      more.textContent = `Showing 100 of ${total} — refine your search`;
      listEl.appendChild(more);
    }
  }

  function updateCount() {
    countEl.textContent = selectedCode ? `Selected: ${selectedCode}` : '';
  }

  let searchTimer: ReturnType<typeof setTimeout>;
  searchInput.addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => renderList(searchInput.value.trim()), 150);
  });

  renderList('');
  updateCount();
  setTimeout(() => searchInput.focus(), 50);
}
