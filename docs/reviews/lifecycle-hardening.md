# Memory and crash review — September 2026

Reviewed against commit `37ccb574`, in the isolated `codex/lifecycle-hardening`
worktree. The supplied review described an older, heavily modified checkout;
its line numbers and some findings no longer describe this revision.

## Verdict on the supplied findings

| Finding | Verdict at this revision | Resolution |
|---|---|---|
| Half-core default creates excessive Stockfish workers | Outdated. `kDefaultWorkers` is now 1, and pool startup is lazy. | Preserve the existing default and explicit user worker settings. Each chosen worker still uses 128 MB of hash; this is not a dynamic RAM budget. |
| Hidden retained screens start/retain inline engines | Confirmed. Most callers use the default `isActive: true`; the old widget also did nothing on deactivation. | Mode-scoped `TickerMode` disables hidden/background panes. Inline bars release their workers on deactivation and restart on return. Both the switch and keyboard toggle notify all bars. |
| Unbounded eval and Maia memory caches | Already fixed. Both use `LruMap` with explicit entry limits. | No duplicate cache implementation or cache-policy change. |
| Superseded player analyses keep running | Confirmed for both cache loads and fresh builds. Identity checks ignored obsolete results but did not stop the work. | Cancellable isolate ownership spans cache load and build; replacement, reset and disposal cancel work. Progress, errors and final publication check the current operation. Parse games individually instead of keeping every parsed game tree alive simultaneously. |
| Eval-tree snapshot and metric construction block the UI and retain duplicate trees | Confirmed. | Saved-tree decoding, snapshot creation and metrics run together off-thread. Large generated trees also prepare off-thread. The view retains the snapshot, metrics and maximum ply, without retaining its own source-tree reference. Clears release layout/measurement caches and cancel unfinished loads. |
| Whole-file PGN counts run concurrently without a bound | Confirmed for file/chapter/study/tactics metadata listings. Folder-only repertoire listing does not read PGN contents. | One counting operation at a time per storage instance, including simultaneous listings. Large counts run off-thread; count metadata has a bounded LRU. Existing file recovery/locking remains in use. |
| FEN-index loading/validation/serialization blocks the UI | Confirmed. | Move codecs and index validation off-thread. Cancel index construction/loading when the collection changes or closes, while preserving pending persistence on shutdown. |
| Failed engine initialization leaks processes | Confirmed in both pool and inline startup. | Dispose failed, superseded and late-arriving workers. Share inline startup, serialize pool provisioning, and invalidate unfinished provisioning on suspension. Bound initialization time. |
| Full-file editable PGN controls and synchronous import processing | Confirmed in substance. Two references to one immutable Dart string do not by themselves prove two string copies, but text layout and parsing are real costs. | Selected files stay outside the editable field; pasted text replaces them. Large counting and analysis-import file loading/header extraction run off-thread. Ignore cancelled/stale completions. Large text decoding and all gzip decompression run off-thread. |

## Additional defects fixed

- An engine connection could arrive after the inline widget was disposed and
  become an orphan. The worker owner now covers creation as well as initialization.
- Concurrent pool provisioning could overshoot the requested count, and crash
  replacement could revive the pool after shutdown. Provisioning is serialized
  and checked against the pool generation.
- An old discovery could resume after its `isready` reply, overwrite the newer
  search's completer, and leave an awaiter hanging. Discovery now checks its stop
  generation before starting and before resetting engine options.
- Failed UCI handshakes leaked stream subscriptions. A shared handshake helper
  closes subscriptions on success, timeout, stream failure and stream closure.
  Mobile readiness listeners also have bounded lifetimes.
- A broken process pipe during `stop` could abort disposal before awaiters and
  the process were cleaned up. Cleanup now continues. Process stream/pipe errors
  are forwarded to the worker, and readiness waits reject dead/disposed workers.
- Old tree loads could publish after a clear or repertoire switch. They are now
  cancelled and cannot publish over the current view.
- Large gzip/text decoding remained synchronous despite asynchronous file reads.
  Decoding now leaves the UI isolate, including small gzip inputs with large
  decompressed contents.

## Validation

Regression coverage includes cancellation during isolate spawn, cancellation of
CPU work, errors/early isolate exit, timeouts, failed/overlapping engine startup,
late connection disposal, overlapping discoveries, handshake listener cleanup,
hidden-mode engine lifetime, FEN-index persistence, and large plain/gzip decoding.
Existing engine, analysis, eval-tree, storage, PGN and main-screen checks are also
run.

- `scripts/doctor.sh --quiet`: passed.
- `scripts/ci.sh analyze lint`: passed with no analyzer issues; layering,
  typography and file-mutation policy checks passed.
- Focused regression run: **156 tests passed**, covering `test/services/engine`,
  `test/services/storage`, `test/features/eval_tree`, unified analysis, isolate
  ownership, inline widgets, PGN imports, file decoding and viewer/main-screen
  lifecycle tests.
- Headless Linux app with a disposable profile: built and launched successfully.
  Inspected screenshots of real Stockfish analysis in Study and the PGN import
  dialog showing the correct count for pasted moves.
- Repeated real Study → Repertoire builder → Study transitions: Stockfish child
  count was **0 while Study was hidden, 1 after returning**, across three cycles.
  The initial transition and return were checked separately too.
- The test app was stopped after the smoke check.
- Full local coverage/offline/integration gates were not completed; those remain
  required on a PR in CI. A full-suite invocation was cancelled in favor of the
  intended focused run. No 100 MB+ library or multi-hour soak test was run.

## Limits

This is a targeted resource-lifetime and crash audit, not proof that every app
path is free of defects. Large libraries and trees still require memory
proportional to their data. LRU limits count entries, not bytes. User-requested
engine concurrency can still exceed a small machine's RAM. No Windows/macOS or
mobile runtime testing was performed in this Linux worktree.
