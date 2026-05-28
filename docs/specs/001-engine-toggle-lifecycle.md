# Engineering Spec: Engine Toggle & Lifecycle Management

**Status:** Draft  
**Feature:** Engine on/off toggle with proper resource management  
**Priority:** P0 — Foundation for all other repertoire builder improvements  
**Estimated effort:** 5-7 days  

---

## Problem Statement

Currently, Stockfish processes are spawned eagerly when a repertoire loads
(`warmUp()` in `repertoire_controller.dart`) and left running until the user
leaves Repertoire mode or the app exits. There is no user-visible toggle.
Engine settings (depth, MultiPV, workers) reset on every app restart.

### Specific bugs / waste today

1. **Wasted CPU/RAM**: Engines run even when user is just browsing the tree or
   reading PGN. On low-end machines, multiple Stockfish processes visibly lag
   the UI.
2. **No toggle UX**: User cannot turn off analysis without leaving the mode.
3. **Settings lost on restart**: EngineSettings is purely in-memory.
4. **Generation + analysis conflict**: Both share a pool without explicit
   mutual exclusion. Starting generation while analysis is in-flight can cause
   pool contention and stale results.
5. **Thread count sticky after generation**: `prepareForTreeBuild(8)` leaves all
   workers at 8 threads, inflating CPU usage for subsequent interactive analysis.
6. **`isActive=false` doesn't cancel**: When generation starts, in-flight
   AnalysisService worker loops continue competing for pool workers.

---

## Design Goals

1. **No engine processes unless the user explicitly opts in** (or generation
   starts its own).
2. **Toggling off immediately releases all engine resources** (processes killed
   within 500ms).
3. **Toggling on brings analysis back within 1s** on the current position.
4. **Settings persist** across app restarts (SharedPreferences).
5. **Generation is fully isolated** from interactive analysis — no resource
   contention, no stale thread counts.
6. **Pre-computed evals shown regardless of toggle** — if we have a cached eval
   or DB eval, show it even when engine is OFF.

---

## Reference: How Lichess Does It

Lichess's `CevalCtrl` (ui/lib/src/ceval/ctrl.ts) provides the gold standard:

| Principle | Lichess | Our adaptation |
|-----------|---------|----------------|
| Lazy worker creation | `this.worker ??= this.engines.make(...)` on first `start()` | Don't call `ensureWorkers()` until toggle ON |
| Stop vs destroy | `stop()` = UCI stop; `destroy()` = kill worker | `stopAll()` vs `dispose()` already exist — wire to toggle |
| Cross-instance coordination | localStorage event disables other tabs | Generation disables analysis toggle (single-app) |
| Settings in storage | `storedIntProp('ceval.multipv', 1)` | SharedPreferences per field |
| Throttled output | 200ms throttle on emit | Debounce result notifier |
| Document visibility | Don't start if hidden | Don't analyze if tab is not Engine/PGN |
| Error recovery | `engineFailed()` → destroy + null worker | Add crash recovery with retry |

Key difference: Lichess has **one worker** (web constraint). We need a **pool**
for generation, but interactive analysis can use 1-2 workers.

---

## Architecture

### State Machine

```
                      ┌──────────────────────────────────┐
                      │                                  │
                      ▼                                  │
┌─────────┐  toggle ON  ┌─────────┐  position   ┌───────────┐
│ ENGINE  │────────────►│ ENGINE  │──change────►│ ANALYZING │
│   OFF   │             │   IDLE  │◄────────────│           │
└─────────┘◄────────────└─────────┘  complete   └───────────┘
     ▲       toggle OFF       │                       │
     │                        │ generation            │ generation
     │                        │ requested             │ requested
     │                        ▼                       ▼
     │                  ┌───────────┐           (cancel analysis
     │                  │ GENERATING│            first, then →)
     │                  │           │
     │                  └───────────┘
     │                        │
     │     generation done    │
     │  (restore previous     │
     │   toggle state)        │
     └────────────────────────┘
```

### States

| State | Pool workers | Analysis | Toggle button |
|-------|-------------|----------|---------------|
| `OFF` | 0 alive | Not running | Unpressed (grey) |
| `IDLE` | N alive, all free | Not running (waiting for position) | Pressed (blue) |
| `ANALYZING` | N alive, some busy | Running on current FEN | Pressed (blue) + spinner |
| `GENERATING` | N alive, all busy | Cancelled | Disabled (locked) |

### Transitions

| From | Event | To | Side effects |
|------|-------|----|--------------|
| OFF | `toggleOn()` | IDLE | `ensureWorkers()`, restore depth/threads from prefs |
| IDLE | position changed | ANALYZING | `runDiscovery()` → `startEvaluation()` |
| ANALYZING | position changed | ANALYZING | Cancel current, start new (generation bump) |
| ANALYZING | complete | IDLE | Results in cache |
| IDLE/ANALYZING | `toggleOff()` | OFF | `AnalysisService.cancel()` + `pool.dispose()` |
| IDLE/ANALYZING | generation requested | GENERATING | `AnalysisService.cancel()`, pool reconfigured |
| GENERATING | generation done/cancelled | previous state | Restore toggle, restore thread count |
| OFF | generation requested | GENERATING | Pool spawned for generation only |

---

## Implementation Plan

### File: `lib/services/engine/engine_lifecycle.dart` (NEW)

Single source of truth for engine state. Replaces the current implicit lifecycle
spread across MainScreen, UnifiedEnginePane, RepertoireController, and
RepertoireGenerationTab.

```dart
enum EngineState { off, idle, analyzing, generating }

/// Coordinates engine lifecycle across analysis and generation.
/// Singleton. Emits state changes via ValueNotifier.
class EngineLifecycle extends ChangeNotifier {
  static final EngineLifecycle _instance = EngineLifecycle._();
  factory EngineLifecycle() => _instance;
  EngineLifecycle._();

  final _pool = StockfishPool();
  final _analysis = AnalysisService();

  EngineState _state = EngineState.off;
  EngineState get state => _state;

  bool _toggleStateBeforeGeneration = false;

  /// User presses toggle button.
  Future<void> toggleOn() async {
    if (_state != EngineState.off) return;
    final settings = EngineSettings();
    await _pool.ensureWorkers(settings.workers, 1);
    _state = EngineState.idle;
    notifyListeners();
  }

  /// User presses toggle button (off).
  Future<void> toggleOff() async {
    if (_state == EngineState.generating) return; // can't toggle during gen
    _analysis.cancel();
    _pool.dispose();
    _state = EngineState.off;
    notifyListeners();
  }

  /// Called when current FEN changes and state is idle/analyzing.
  void onPositionChanged(String fen) {
    if (_state == EngineState.off || _state == EngineState.generating) return;
    _state = EngineState.analyzing;
    notifyListeners();
    // Actual analysis triggered by UnifiedEnginePane via AnalysisService
  }

  /// Called when AnalysisService completes.
  void onAnalysisComplete() {
    if (_state == EngineState.analyzing) {
      _state = EngineState.idle;
      notifyListeners();
    }
  }

  /// Called before generation starts.
  Future<void> enterGeneration(int threads) async {
    _toggleStateBeforeGeneration = _state != EngineState.off;
    _analysis.cancel();
    // Don't dispose — reconfigure for generation
    await _pool.prepareForTreeBuild(threads);
    _state = EngineState.generating;
    notifyListeners();
  }

  /// Called when generation finishes or is cancelled.
  Future<void> exitGeneration() async {
    // Reset thread count to interactive settings
    final settings = EngineSettings();
    if (_toggleStateBeforeGeneration) {
      await _pool.reconfigureAllWorkers(1);
      await _pool.ensureWorkers(settings.workers, 1);
      _state = EngineState.idle;
    } else {
      _pool.dispose();
      _state = EngineState.off;
    }
    notifyListeners();
  }
}
```

### File: `lib/models/engine_settings.dart` (MODIFY)

Add SharedPreferences persistence:

```dart
class EngineSettings extends ChangeNotifier {
  // ... existing fields ...

  static const _prefix = 'engine_settings.';

  /// Load saved settings on construction.
  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _workers = prefs.getInt('${_prefix}workers') ?? _defaultWorkers;
    _depth = prefs.getInt('${_prefix}depth') ?? 20;
    _multiPv = prefs.getInt('${_prefix}multi_pv') ?? 3;
    _easeDepth = prefs.getInt('${_prefix}ease_depth') ?? 18;
    _maiaElo = prefs.getInt('${_prefix}maia_elo') ?? 1500;
    _showStockfish = prefs.getBool('${_prefix}show_stockfish') ?? true;
    _showMaia = prefs.getBool('${_prefix}show_maia') ?? true;
    _showDifficulty = prefs.getBool('${_prefix}show_difficulty') ?? true;
    _showProbability = prefs.getBool('${_prefix}show_probability') ?? true;
    // engineEnabled is persisted separately by EngineLifecycle
    notifyListeners();
  }

  /// Persist on every change.
  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('${_prefix}workers', _workers);
    await prefs.setInt('${_prefix}depth', _depth);
    // ... all fields ...
  }

  // Modify each setter to call _persist():
  set workers(int v) {
    if (v == _workers) return;
    _workers = v;
    _persist();
    notifyListeners();
  }
  // ... same pattern for all setters ...
}
```

### File: `lib/widgets/engine/engine_toggle_button.dart` (NEW)

```dart
/// Board toolbar button for engine on/off.
/// Shows state via icon color and optional spinner.
class EngineToggleButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: EngineLifecycle(),
      builder: (context, _) {
        final state = EngineLifecycle().state;
        final isOn = state != EngineState.off;
        final isGenerating = state == EngineState.generating;

        return IconButton(
          icon: Icon(
            Icons.bolt,
            color: isGenerating
                ? Colors.grey
                : isOn
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
          ),
          tooltip: isGenerating
              ? 'Engine busy (generating)'
              : isOn
                  ? 'Disable engine analysis'
                  : 'Enable engine analysis',
          onPressed: isGenerating
              ? null
              : () {
                  if (isOn) {
                    EngineLifecycle().toggleOff();
                  } else {
                    EngineLifecycle().toggleOn();
                  }
                },
        );
      },
    );
  }
}
```

### Modifications to existing files

#### `lib/widgets/engine/unified_engine_pane.dart`

```diff
- // Current: always attempts analysis when isActive
+ // New: only analyze when EngineLifecycle.state != off
  void _onPositionChanged() {
+   if (EngineLifecycle().state == EngineState.off) {
+     // Show cached/DB evals only
+     _showPreComputedEval();
+     return;
+   }
    _startInitialAnalysis();
  }
```

Remove the `isActive` prop — lifecycle is now managed by `EngineLifecycle`, not
by the parent widget.

#### `lib/screens/main_screen.dart`

```diff
- void _disposeEngineResources() {
-   AnalysisService().dispose();
-   StockfishPool().dispose();
- }
+ // No longer needed — EngineLifecycle.toggleOff() handles this,
+ // and leaving repertoire mode calls toggleOff().
+ void _onModeChanged(AppMode prev, AppMode curr) {
+   if (prev == AppMode.repertoire && curr != AppMode.repertoire) {
+     EngineLifecycle().toggleOff();
+   }
+ }
```

#### `lib/widgets/repertoire_generation_tab.dart`

```diff
  Future<void> _startGeneration() async {
-   // Current: sets _isGenerating, hopes analysis stops
+   await EngineLifecycle().enterGeneration(config.resolvedEngineThreads);
    // ... generation code ...
  }

  void _onGenerationComplete() {
-   // Current: sets _isGenerating = false
+   await EngineLifecycle().exitGeneration();
    // ...
  }
```

#### `lib/services/tree_build_service.dart`

```diff
  Future<void> build(...) async {
-   await _pool.prepareForTreeBuild(cfg.resolvedEngineThreads);
+   // Pool already configured by EngineLifecycle.enterGeneration()
    // ...

    // ADD: on cancel, call stopAll to kill in-flight searches
    if (!_isBuilding || isCancelled()) {
+     _pool.stopAll();
      break;
    }
  }
```

---

## Edge Cases & Solutions

### 1. Rapid toggle on/off/on

**Problem:** User clicks toggle rapidly. `ensureWorkers()` is async — what if
`toggleOff()` is called before workers finish spawning?

**Solution:** Use a serial async queue (Dart `Completer` chain):

```dart
Future<void> _serialExec(Future<void> Function() fn) async {
  _queueTail = _queueTail.then((_) => fn());
  await _queueTail;
}

Future<void> toggleOn() => _serialExec(_doToggleOn);
Future<void> toggleOff() => _serialExec(_doToggleOff);
```

### 2. Generation requested while toggle is OFF

**Problem:** User has engine OFF, clicks Generate. Should it work?

**Solution:** Yes. `enterGeneration()` spawns workers regardless of toggle
state. `_toggleStateBeforeGeneration` tracks that toggle was OFF, so
`exitGeneration()` disposes workers (not re-enables interactive analysis).

### 3. App backgrounded (mobile/laptop lid closed)

**Problem:** Engines burn CPU in background.

**Solution:** In `didChangeAppLifecycleState`:
- `paused`/`inactive`: `AnalysisService().cancel()` + `pool.stopAll()` (stop
  searches, keep processes alive for fast resume)
- `detached`: `EngineLifecycle().toggleOff()` (full dispose)
- `resumed`: If toggle was on, restart analysis on current position

### 4. Engine process crashes

**Problem:** Stockfish segfaults. Currently, the stream error propagates but the
worker stays in `_busy` forever.

**Solution:** Add to `EvalWorker`:

```dart
void _onStreamError(Object error) {
  _evalCompleter?.completeError(error);
  _discoveryCompleter?.completeError(error);
  // Notify pool to remove this worker
  onCrash?.call(this);
}
```

Pool adds crash handler:

```dart
void _handleWorkerCrash(EvalWorker worker) {
  _workers.remove(worker);
  _free.remove(worker);
  _busy.remove(worker);
  worker.dispose(); // cleanup process
  // Optionally re-spawn if toggle is ON:
  if (EngineLifecycle().state != EngineState.off) {
    _spawnOne().then((w) { if (w != null) _free.add(w); });
  }
}
```

### 5. Toggle OFF while AnalysisService worker loops are mid-eval

**Problem:** Worker loop is `await pool.acquire()` → eval → release. If we
`dispose()` pool mid-loop, `release()` throws or is no-op.

**Solution:** `toggleOff()` calls `_analysis.cancel()` FIRST (bumps generation
counter, loops exit at next checkpoint), THEN `_pool.dispose()`. The 500ms
between cancel and dispose is guaranteed by the serial queue:

```dart
Future<void> _doToggleOff() async {
  _analysis.cancel(); // immediate: bumps _generation, loops will exit
  await Future.delayed(const Duration(milliseconds: 100));
  // By now all loops have hit their generation check and bailed
  _pool.dispose();
  _state = EngineState.off;
  notifyListeners();
}
```

### 6. Pre-computed eval display when engine is OFF

**Problem:** User has engine OFF but we have a cached eval from prior session or
from the generated tree. Should we show it?

**Solution:** Yes, always. `UnifiedEnginePane` checks eval sources in order:
1. In-memory `_analysisCache` (from prior analysis in this session)
2. `BuildTree` node eval (if tree loaded)
3. `EvalCache` SQLite
4. ChessDB/CdbDirect

If any hit, display with a "cached" badge. No engine processes needed.

---

## Testing Strategy

### Unit tests

| Test | Verifies |
|------|----------|
| `EngineLifecycle` state transitions | All valid transitions, invalid transitions rejected |
| Serial queue | Rapid toggle doesn't cause race |
| `enterGeneration` / `exitGeneration` | State correctly saved/restored |
| `EngineSettings` persistence | Round-trip through SharedPreferences |

### Integration tests

| Test | Verifies |
|------|----------|
| Toggle ON → position change → results received | Full pipeline works |
| Toggle OFF → no processes alive | `pgrep stockfish` returns empty |
| Generation → analysis resume | Thread count restored, analysis resumes |
| Worker crash → recovery | New worker spawned, analysis retries |

### Performance tests

| Metric | Target | How to measure |
|--------|--------|----------------|
| Toggle ON → first eval displayed | < 1.5s | Stopwatch from tap to notifier update |
| Toggle OFF → all processes dead | < 500ms | Process monitor |
| Position change → new eval displayed | < 200ms for cached, < 2s for depth-20 | UI frame timing |
| Memory after toggle OFF | Return to pre-ON baseline within 5s | `ProcessInfo.rss` |

---

## Migration Path

1. Add `EngineLifecycle` + `EngineToggleButton` (new files, no existing code touched)
2. Add persistence to `EngineSettings` (additive change, backward compatible)
3. Wire `EngineLifecycle.enterGeneration/exitGeneration` into generation tab
4. Modify `UnifiedEnginePane` to respect lifecycle state (remove `isActive` prop)
5. Modify `MainScreen` to delegate to lifecycle instead of manual dispose
6. Add crash recovery to pool
7. Remove dead code: `suspend()`, duplicate `dispose()` calls, `isActive` prop threading

Each step is independently testable and deployable. No big-bang refactor.

---

## What This Enables

With this foundation:
- **Browse Mode** can check `EngineLifecycle.state` to decide whether to show
  live engine candidates or DB-only candidates
- **Coverage Suggestions** can use the pool (via `evaluateFen`) only when engine
  is on, falling back to cached/DB evals otherwise
- **Eval bar toggle** is just a thin wrapper around `EngineToggleButton`
- **"Calculate all nodes"** mode can call `enterGeneration()` then walk tree
- **Expectimax Lines Panel** (spec 009) can run alongside or independently of
  the engine — it reads precomputed tree data with zero Stockfish overhead, or
  triggers on-the-fly BFS when deeper computation is needed

---

## Expectimax Toggle: Dual-Toggle Toolbar (spec 009)

The board toolbar hosts **two independent toggle buttons** — one for the
Stockfish engine, one for the expectimax lines panel:

```
[⚡ Engine]  [🎯 Expectimax]
```

### Interaction between Engine and Expectimax toggles

| Engine | Expectimax | Behavior |
|--------|-----------|----------|
| OFF | OFF | No analysis pane. Board shows cached evals only. |
| ON | OFF | Stockfish MultiPV lines in context panel (current behavior). |
| OFF | ON | Expectimax lines from precomputed tree (zero CPU — reads tree data). |
| ON | ON | Both panels visible (split or tabbed). Engine provides live eval; Expectimax provides practical lines. |

Key design points:

1. **No resource contention when both ON.** Expectimax reads `BuildTree` nodes
   in memory — no Stockfish processes needed. Only on-the-fly BFS (spec 009
   Part 3) uses engine workers, and it self-limits to 1-2 threads.

2. **Expectimax toggle independent of `EngineState`.** The expectimax panel
   tracks its own state via `ExpectimaxPanelState` (off / active / computing).
   It does NOT go through `EngineLifecycle` for precomputed data reads. Only
   on-the-fly BFS interacts with `EngineLifecycle` (checks if generation is
   running; pauses if so).

3. **On-the-fly BFS and generation mutual exclusion.** If the user clicks
   "Compute deeper" (spec 009) while full generation is running,
   `EngineLifecycle.state == generating` blocks the on-the-fly build. The
   expectimax panel shows "Engine busy — generation in progress." If on-the-fly
   BFS is running and the user starts full generation, on-the-fly is cancelled
   first via `OnTheFlyExpectimaxService.cancel()`.

### `ExpectimaxToggleButton` widget

```dart
/// Board toolbar toggle for the expectimax lines panel.
/// Independent from EngineToggleButton — both can be ON simultaneously.
class ExpectimaxToggleButton extends StatelessWidget {
  final bool isActive;
  final bool hasTree;
  final bool isComputing;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        Icons.insights,
        color: isComputing
            ? Colors.orange
            : isActive
                ? Colors.green
                : Colors.grey,
      ),
      tooltip: isComputing
          ? 'Computing expectimax...'
          : isActive
              ? 'Hide expectimax lines'
              : hasTree
                  ? 'Show expectimax lines'
                  : 'No tree loaded — compute on the fly',
      onPressed: onToggle,
    );
  }
}
```

### Additions to `EngineState`

No new enum values needed. The expectimax panel is **not** an engine state — it
is a separate UI toggle that reads tree data. The `EngineLifecycle` state
machine remains unchanged. On-the-fly BFS coordination uses
`EngineLifecycle.state` as a read-only check, not a new state.

---

## Open Questions

1. **Should toggle state persist across restarts?** Lichess does NOT persist
   (always off on page load). Recommend: persist toggle state, default OFF on
   first install.
2. **Should inline engine bar (PGN viewer) share this lifecycle?** Currently it
   has its own dedicated worker. Recommend: keep separate for now, unify later.
3. **Worker count during interactive analysis:** Currently uses
   `EngineSettings.workers` (half of cores). Should we reduce to 1-2 for
   interactive to save CPU? Recommend: default 1 worker for interactive, full
   count only for generation.
4. **Should both toggles persist independently?** Recommend: yes. Engine toggle
   and expectimax toggle each save their last state to SharedPreferences.
   Expectimax defaults to ON if a tree is loaded, OFF otherwise.
