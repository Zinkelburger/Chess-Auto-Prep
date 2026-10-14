/**
 * Bughouse Single Board: Crazyhouse Analysis's board, move list and editor
 * with bughouse rules for one board and Hivemind as the engine. The partner
 * board is never shown: Hivemind sees it as the starting position, held
 * still, with every piece missing from this board in the pocket of whoever
 * captured it there. Pieces arrive only when you add them with +.
 */
import { CrazyhouseApp } from '../crazyhouse/app';
import { useBughouseRules } from '../crazyhouse/tree';
import { HivemindEngine } from './engine';
import { MAX_SIT_WORKERS, SitPanel } from './sit';

/** Hivemind's own practice strength, as in the Bughouse Lab. */
const PRACTICE_NODES = 200;

export function startBughouseSingleBoard() {
  useBughouseRules();
  const cores = Math.max(1, navigator.hardwareConcurrency || 2);
  const maxThreads = Math.max(1, Math.min(MAX_SIT_WORKERS, cores - 1));
  new CrazyhouseApp({
    engine: (onStatus, onResult) => new HivemindEngine(onStatus, onResult),
    engineName: 'Hivemind',
    treeKey: 'bughouse-single-board-tree-v1',
    settingsKey: 'bughouse-single-board-v1',
    // Each sit worker holds its own network: two leave a phone room to breathe.
    settingsDefaults: { multiPv: 2, threads: Math.min(2, maxThreads), sitNodes: 200 },
    practiceNodes: PRACTICE_NODES,
    maxThreads,
    extra: (host) => new SitPanel(host, document.getElementById('bs-sit')!),
  });
}
