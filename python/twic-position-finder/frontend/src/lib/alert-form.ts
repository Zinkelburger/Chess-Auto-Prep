/**
 * One alert form — label, filters, time-control / result / online options —
 * used both by the anonymous "create your first alert" flow and by the
 * signed-in list (create and edit). The DOM comes from <AlertFields/>; this
 * class owns reading, writing and validating it.
 */
import type { AlertPayload, Subscription } from './api';
import { FilterBuilder, hasMatchKey } from './filters';
import {
  DEFAULT_EXCLUDE_SITE, readExcludeOnline, readResult, readTimeControl,
  writeExcludeOnline, writeResult, writeTimeControl,
} from './form-options';

/**
 * Values the server stores that this form cannot express. PUT replaces the
 * whole row, so an edit that did not send them back would silently erase
 * them — and a subscription whose only match key is `white`/`black` could
 * not be saved at all. `exclude_site` is here because the form shows it as a
 * checkbox, which cannot say *which* site a custom value excluded.
 */
type Carried = Pick<AlertPayload, 'white' | 'black' | 'site' | 'exclude_site'>;

export class AlertForm {
  private readonly prefix: string;
  private readonly filters: FilterBuilder;
  private readonly labelInput: HTMLInputElement;
  private carried: Carried = {};

  constructor(root: HTMLElement, prefix: string) {
    this.prefix = prefix;
    this.labelInput = root.querySelector<HTMLInputElement>(`#${prefix}-label`)!;
    this.filters = new FilterBuilder({
      container: root.querySelector<HTMLElement>(`#${prefix}-filters`)!,
      addBtn: root.querySelector<HTMLButtonElement>(`#${prefix}-add-filter`)!,
      menu: root.querySelector<HTMLElement>(`#${prefix}-filter-menu`)!,
      idPrefix: prefix,
    });
    this.reset();
  }

  /** Empty form with the defaults (one FEN row, all time controls/results, online excluded). */
  reset(): void {
    this.labelInput.value = '';
    this.carried = {};
    writeTimeControl(this.prefix, null);
    writeResult(this.prefix, null);
    writeExcludeOnline(`${this.prefix}-exclude-online`, DEFAULT_EXCLUDE_SITE);
    this.filters.resetDefault();
  }

  load(sub: Subscription): void {
    this.labelInput.value = sub.label ?? '';
    this.carried = {
      white: sub.white ?? undefined,
      black: sub.black ?? undefined,
      site: sub.site ?? undefined,
      exclude_site: sub.exclude_site ?? undefined,
    };
    writeTimeControl(this.prefix, sub.time_control);
    writeResult(this.prefix, sub.result);
    writeExcludeOnline(`${this.prefix}-exclude-online`, sub.exclude_site);
    this.filters.setFromSubscription(sub);
  }

  focus(): void {
    this.labelInput.focus();
  }

  /** Returns the payload, or a user-facing validation message. */
  read(): { ok: true; payload: AlertPayload } | { ok: false; error: string } {
    const v = this.filters.values();
    if (!hasMatchKey(v) && !this.carried.white && !this.carried.black) {
      return { ok: false, error: 'Add at least one position, player, or opening — Elo and event alone would match every game.' };
    }
    if (v.min_elo !== undefined && v.max_elo !== undefined && v.min_elo > v.max_elo) {
      return { ok: false, error: 'Minimum Elo is above maximum Elo.' };
    }
    const timeControl = readTimeControl(this.prefix);
    if (timeControl === null) {
      return { ok: false, error: 'Pick at least one time control.' };
    }
    const result = readResult(this.prefix);
    if (result === null) {
      return { ok: false, error: 'Pick at least one result.' };
    }
    return {
      ok: true,
      payload: {
        ...this.carried,
        label: this.labelInput.value.trim(),
        fen: v.fens.length > 0 ? v.fens : undefined,
        player: v.player,
        eco: v.eco,
        min_elo: v.min_elo,
        max_elo: v.max_elo,
        event: v.event,
        time_control: timeControl,
        result,
        exclude_site: readExcludeOnline(`${this.prefix}-exclude-online`, this.carried.exclude_site),
      },
    };
  }
}
