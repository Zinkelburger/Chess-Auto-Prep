/** Player / event name autocomplete against static TWIC JSON dumps. */

function matchesQuery(entry: string, words: string[]): boolean {
  const lower = entry.toLowerCase();
  return words.every((w) => lower.includes(w));
}

function fillList(box: HTMLElement, entries: string[], onPick: (name: string) => void): void {
  box.replaceChildren();
  for (const name of entries) {
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'ac-item';
    row.textContent = name;
    row.addEventListener('click', () => onPick(name));
    box.appendChild(row);
  }
}

export function setupAutocomplete(
  jsonUrl: string,
  input: HTMLInputElement,
  status: HTMLElement,
  matchBox: HTMLElement,
  label: string,
  minChars = 2,
): void {
  let dataset: string[] = [];
  fetch(jsonUrl)
    .then((r) => r.json())
    .then((d: unknown) => {
      if (Array.isArray(d)) dataset = d.filter((x): x is string => typeof x === 'string');
    })
    .catch(() => {});

  let timer: ReturnType<typeof setTimeout>;

  input.addEventListener('input', () => {
    clearTimeout(timer);
    const raw = input.value.trim();
    if (!raw || raw.length < minChars || dataset.length === 0) {
      status.hidden = true;
      matchBox.hidden = true;
      return;
    }

    timer = setTimeout(() => {
      const words = raw.toLowerCase().split(/[\s,]+/).filter((w) => w.length > 0);
      const matches = dataset.filter((e) => matchesQuery(e, words));
      status.hidden = false;
      matchBox.hidden = false;

      if (matches.length > 0) {
        status.textContent = '✓';
        status.className = 'ac-status ac-status-ok';
        status.title = `Matches ${matches.length} ${label}(s) in TWIC`;
        fillList(matchBox, matches.slice(0, 10), (name) => {
          input.value = name;
          input.dispatchEvent(new Event('input'));
        });
        if (matches.length > 10) {
          const more = document.createElement('div');
          more.className = 'ac-more';
          more.textContent = `…and ${matches.length - 10} more`;
          matchBox.appendChild(more);
        }
        return;
      }

      status.textContent = '✗';
      status.className = 'ac-status ac-status-miss';
      status.title = `No matching ${label}s in TWIC data`;

      if (label === 'player' && words.length > 1) {
        const longest = words.reduce((a, b) => (a.length >= b.length ? a : b));
        const fallback = dataset.filter((e) => e.toLowerCase().includes(longest));
        if (fallback.length > 0) {
          matchBox.replaceChildren();
          const hint = document.createElement('div');
          hint.className = 'ac-hint';
          hint.textContent = `No exact match — TWIC often abbreviates first names. Try “${longest}”:`;
          matchBox.appendChild(hint);
          fillList(matchBox, fallback.slice(0, 8), (name) => {
            input.value = name;
            input.dispatchEvent(new Event('input'));
          });
          return;
        }
      }

      matchBox.replaceChildren();
      const empty = document.createElement('div');
      empty.className = 'ac-hint';
      empty.textContent = `No matching ${label}s in TWIC data`;
      matchBox.appendChild(empty);
    }, 300);
  });
}
