/**
 * Keeps the keyboard focus through a redraw. The hands, the piece values and
 * the engine lines are drawn again on every change (and the lines on every
 * engine report), which would drop the focus on the page each time: a player
 * pressing + twice, or reading along an engine line, would lose their place.
 * Controls that can hold the focus carry `data-focus`, a name that stays the
 * same from one drawing to the next.
 */
export function keepFocus(box: HTMLElement, render: () => void) {
  const active = document.activeElement as HTMLElement | null;
  const key = active && box.contains(active) ? active.dataset.focus : undefined;
  render();
  if (!key || box.contains(document.activeElement)) return;
  const again = box.querySelector<HTMLElement>(`[data-focus="${CSS.escape(key)}"]`);
  if (!again) return;
  if (!again.matches(':disabled')) { again.focus({ preventScroll: true }); return; }
  // A − that has nothing left to take names its + (`data-focus-alt`).
  const alt = again.dataset.focusAlt && box.querySelector<HTMLElement>(`[data-focus="${CSS.escape(again.dataset.focusAlt)}"]`);
  if (alt && !alt.matches(':disabled')) { alt.focus({ preventScroll: true }); return; }
  // Otherwise the nearest control beside it in its row.
  const row = [...(again.parentElement?.children ?? [])] as HTMLElement[];
  const at = row.indexOf(again);
  const near = row
    .map((el, i) => ({ el, d: Math.abs(i - at) }))
    .filter(({ el }) => el.dataset.focus && !el.matches(':disabled'))
    .sort((a, b) => a.d - b.d)[0]?.el;
  near?.focus({ preventScroll: true });
}
