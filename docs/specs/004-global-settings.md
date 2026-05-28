# Engineering Spec: Global Settings Screen

**Status:** Draft  
**Feature:** Centralized, persistent settings for the repertoire builder  
**Priority:** P0 — Users currently lose all engine config on restart  
**Depends on:** 001-engine-toggle-lifecycle (persists engine settings)  
**Estimated effort:** 1 week  

---

## Problem Statement

Settings are currently scattered across:
- **EngineSettings** (in-memory only — lost on restart)
- **EvalDatabaseSettings** (persisted but only accessible from Actions tab)
- **TrainingSettings** (persisted but only accessible from Trainer settings tab)
- **LichessAuthService** (persisted tokens, no UI for status/disconnect)
- **AppState** (usernames, pending paths)
- **Generation config** (per-session, not saved as defaults)

There is **no single place** where the user can configure their setup. Engine
depth, worker count, ChessDB path, Lichess auth status, and generation defaults
all require navigating to different tabs and are not discoverable.

---

## Design Goals

1. **One screen, all config**: Accessible from app bar gear icon (any mode)
2. **Persisted**: Every setting survives app restart via SharedPreferences
3. **Grouped by concern**: Engine, Database, Accounts, Generation, Training, UI
4. **Validated**: Invalid inputs (bad paths, out-of-range values) rejected with feedback
5. **Non-destructive**: Changing settings doesn't destroy in-progress work
6. **Discoverable**: New users can find and understand all options

---

## Settings Inventory

### Engine Settings (currently EngineSettings singleton)

| Setting | Type | Default | Range | Persisted today? |
|---------|------|---------|-------|------------------|
| Workers (interactive analysis) | int | cores/2 | 1..cores | NO |
| Workers (generation) | int | cores-1 | 1..cores | NO |
| Depth (interactive) | int | 20 | 1..99 | NO |
| Depth (ease calculation) | int | 18 | 1..99 | NO |
| MultiPV | int | 3 | 1..10 | NO |
| Inline threads (PGN viewer) | int | 1 | 1..cores | NO |
| Max analysis moves | int | 8 | 3..20 | NO |
| Show Stockfish in engine pane | bool | true | — | NO |
| Show Maia | bool | true | — | NO |
| Show difficulty | bool | true | — | NO |
| Show probability | bool | true | — | NO |
| Maia ELO | int | 1500 | 600..2400 | NO |
| Engine enabled on startup | bool | false | — | NO |
| Stockfish binary path | String? | auto-detect | valid path | NO |

### Database Settings (currently EvalDatabaseSettings)

| Setting | Type | Default | Range | Persisted today? |
|---------|------|---------|-------|------------------|
| CdbDirect enabled | bool | false | — | YES |
| CdbDirect database path | String | '' | valid directory | YES |
| CdbDirect read-ahead | bool | false | — | YES |
| ChessDB.cn API enabled | bool | true | — | NO (hardcoded) |
| ChessDB.cn daily quota | int | 1000 | 100..10000 | NO |
| Lichess DB enabled | bool | true | — | NO |

### Account Settings

| Setting | Type | Default | Persisted today? |
|---------|------|---------|------------------|
| Lichess auth status | display only | — | YES (tokens) |
| Lichess username | display only | — | YES |
| Chess.com username | String? | null | YES |

### Generation Defaults

| Setting | Type | Default | Range | Persisted today? |
|---------|------|---------|-------|------------------|
| Default build mode | enum | stockfishExpectimax | 2 valid modes | NO |
| Default depth (generation) | int | 10 | 1..30 | NO |
| Our MultiPV | int | 3 | 1..10 | NO |
| Max eval loss (cp) | int | 50 | 10..200 | NO |
| Opponent source | enum | maia | maia/lichess | NO |
| Min probability cutoff | double | 0.01 | 0.001..0.1 | NO |
| Coverage threshold | double | 0.01 | 0.001..0.1 | NO |
| Selection mode | enum | expectimax | 3 modes | NO |

### Training Settings (currently TrainingSettings — already persisted)

| Setting | Type | Default | Persisted? |
|---------|------|---------|------------|
| Correct streak threshold | int | 3 | YES |
| Training depth | int? | null (full) | YES |
| Auto-next | bool | false | YES |
| Wrong move replay | bool | true | YES |
| Learn requires click | bool | true | YES |
| Learn delay (sec) | int | 3 | YES |
| Show rating buttons | bool | true | YES |
| Review order | enum | byImportance | YES |

### UI Settings (new)

| Setting | Type | Default | Persisted? |
|---------|------|---------|------------|
| Board theme | enum | default | NO (new) |
| Piece set | enum | default | NO (new) |
| Notation style | enum | san | NO (new) |
| Show coordinates | bool | true | NO (new) |
| Default repertoire mode | enum | edit | NO (new) |
| Compact eval display | bool | false | NO (new) |

---

## Screen Layout

```
┌─ Settings ──────────────────────────────────────────────────────────┐
│ ← Back                                                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│ ▸ Engine                                                            │
│   Workers: [══●══════] 4/8 cores                                   │
│   Depth:   [════●════] 20                                          │
│   MultiPV: [●═════════] 3                                          │
│   Maia ELO: [════●════] 1500                                       │
│   Engine on startup: [ ] OFF                                        │
│   Stockfish path: [auto-detect          ] [Browse...]               │
│                                                                     │
│ ▸ Database                                                          │
│   ChessDB offline:  [✓] Enabled                                    │
│   Database path: [/mnt/ssd/chessdb     ] [Browse...]               │
│   Read-ahead: [ ] OFF                                               │
│   ChessDB.cn API: [✓] Enabled (quota: 847/1000 today)             │
│   Lichess DB: [✓] Enabled                                          │
│                                                                     │
│ ▸ Accounts                                                          │
│   Lichess: Connected as "username" [Disconnect]                     │
│   Chess.com: [username          ] [Save]                            │
│                                                                     │
│ ▸ Generation Defaults                                               │
│   Build mode: [Stockfish + Expectimax ▼]                           │
│   Depth: 10 ply    Our MultiPV: 3                                  │
│   Max eval loss: 50cp    Opponent: [Maia ▼]                        │
│   Probability cutoff: 1%                                            │
│   Selection: [Expectimax ▼]                                        │
│                                                                     │
│ ▸ Training (opens existing TrainingSettings UI)                     │
│                                                                     │
│ ▸ Display                                                           │
│   Notation: [SAN ▼]  Coordinates: [✓]                             │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│ [Reset All to Defaults]                           App version 1.2.3 │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Implementation

### File: `lib/services/settings_service.dart` (NEW)

Central persistence layer. Wraps SharedPreferences with typed getters/setters.

```dart
/// Centralized settings persistence.
/// Loads all settings on app start, provides typed access.
class SettingsService {
  static final SettingsService _instance = SettingsService._();
  factory SettingsService() => _instance;
  SettingsService._();

  late SharedPreferences _prefs;
  bool _loaded = false;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _loaded = true;
  }

  // --- Engine ---
  int get engineWorkers => _prefs.getInt('engine.workers') ?? _defaultWorkers;
  set engineWorkers(int v) => _prefs.setInt('engine.workers', v);

  int get engineDepth => _prefs.getInt('engine.depth') ?? 20;
  set engineDepth(int v) => _prefs.setInt('engine.depth', v);

  int get engineMultiPv => _prefs.getInt('engine.multi_pv') ?? 3;
  set engineMultiPv(int v) => _prefs.setInt('engine.multi_pv', v);

  int get maiaElo => _prefs.getInt('engine.maia_elo') ?? 1500;
  set maiaElo(int v) => _prefs.setInt('engine.maia_elo', v);

  bool get engineOnStartup => _prefs.getBool('engine.on_startup') ?? false;
  set engineOnStartup(bool v) => _prefs.setBool('engine.on_startup', v);

  String? get stockfishPath => _prefs.getString('engine.stockfish_path');
  set stockfishPath(String? v) {
    if (v == null) _prefs.remove('engine.stockfish_path');
    else _prefs.setString('engine.stockfish_path', v);
  }

  // --- Database ---
  // Delegate to existing EvalDatabaseSettings (already persisted)

  // --- Generation Defaults ---
  int get genDepth => _prefs.getInt('gen.depth') ?? 10;
  set genDepth(int v) => _prefs.setInt('gen.depth', v);

  int get genOurMultiPv => _prefs.getInt('gen.our_multi_pv') ?? 3;
  set genOurMultiPv(int v) => _prefs.setInt('gen.our_multi_pv', v);

  int get genMaxEvalLoss => _prefs.getInt('gen.max_eval_loss') ?? 50;
  set genMaxEvalLoss(int v) => _prefs.setInt('gen.max_eval_loss', v);

  // ... all other settings follow same pattern ...

  /// Reset all settings to defaults.
  Future<void> resetAll() async {
    final keys = _prefs.getKeys().where((k) =>
      k.startsWith('engine.') ||
      k.startsWith('gen.') ||
      k.startsWith('ui.')
    );
    for (final k in keys) {
      await _prefs.remove(k);
    }
  }

  static int get _defaultWorkers =>
      (Platform.numberOfProcessors / 2).clamp(1, 8).toInt();
}
```

### File: `lib/screens/settings_screen.dart` (NEW)

```dart
/// Full-screen settings. Accessed from gear icon in any app mode.
class SettingsScreen extends StatefulWidget {
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsService();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildEngineSection(),
          _buildDatabaseSection(),
          _buildAccountsSection(),
          _buildGenerationSection(),
          _buildTrainingSection(),
          _buildDisplaySection(),
          const SizedBox(height: 24),
          _buildResetButton(),
        ],
      ),
    );
  }

  Widget _buildEngineSection() {
    return _SettingsGroup(
      title: 'Engine',
      children: [
        _SliderSetting(
          label: 'Workers (interactive)',
          value: _settings.engineWorkers,
          min: 1, max: Platform.numberOfProcessors,
          onChanged: (v) => setState(() => _settings.engineWorkers = v),
        ),
        _SliderSetting(
          label: 'Search depth',
          value: _settings.engineDepth,
          min: 1, max: 40,
          onChanged: (v) => setState(() => _settings.engineDepth = v),
        ),
        // ... other engine settings ...
        _PathSetting(
          label: 'Stockfish binary',
          value: _settings.stockfishPath,
          placeholder: 'Auto-detect (bundled)',
          onChanged: (v) => setState(() => _settings.stockfishPath = v),
        ),
      ],
    );
  }

  Widget _buildDatabaseSection() {
    final dbSettings = EvalDatabaseSettings.instance;
    return ListenableBuilder(
      listenable: dbSettings,
      builder: (context, _) => _SettingsGroup(
        title: 'Database',
        children: [
          _SwitchSetting(
            label: 'ChessDB offline database',
            value: dbSettings.enableCdbDirect,
            onChanged: (v) => dbSettings.setEnableCdbDirect(v),
          ),
          if (dbSettings.enableCdbDirect)
            _PathSetting(
              label: 'Database path',
              value: dbSettings.cdbDirectPath,
              onChanged: (v) => dbSettings.setCdbDirectPath(v),
              validate: _validateDbPath,
            ),
          // ... ChessDB.cn quota display ...
        ],
      ),
    );
  }

  Widget _buildAccountsSection() {
    final lichess = LichessAuthService();
    return ListenableBuilder(
      listenable: lichess,
      builder: (context, _) => _SettingsGroup(
        title: 'Accounts',
        children: [
          _AccountRow(
            service: 'Lichess',
            isConnected: lichess.isAuthenticated,
            username: lichess.username,
            onConnect: () => lichess.startOAuthFlow(),
            onDisconnect: () => lichess.logout(),
          ),
          // Chess.com username field
        ],
      ),
    );
  }
}
```

### Modifications to existing code

#### `lib/models/engine_settings.dart`

Replace in-memory defaults with `SettingsService` reads:

```dart
class EngineSettings extends ChangeNotifier {
  EngineSettings._() {
    // Load from SettingsService on construction
    final s = SettingsService();
    _workers = s.engineWorkers;
    _depth = s.engineDepth;
    _multiPv = s.engineMultiPv;
    _maiaElo = s.maiaElo;
    // ... etc
  }

  // Setters now persist:
  set workers(int v) {
    if (v == _workers) return;
    _workers = v;
    SettingsService().engineWorkers = v;
    notifyListeners();
  }
}
```

#### `lib/screens/repertoire_screen.dart` (app bar)

Add gear icon that opens settings:

```dart
actions: [
  // ... existing actions ...
  IconButton(
    icon: const Icon(Icons.settings),
    tooltip: 'Settings',
    onPressed: () => Navigator.push(context,
      MaterialPageRoute(builder: (_) => const SettingsScreen())),
  ),
],
```

#### `lib/main.dart`

Initialize SettingsService early:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsService().init();
  await EvalDatabaseSettings.instance.load();
  runApp(const ChessAutoPrepApp());
}
```

---

## Validation Rules

| Setting | Validation | Error message |
|---------|-----------|---------------|
| Stockfish path | File exists + executable | "File not found or not executable" |
| CdbDirect path | Directory exists + contains expected files | "No valid ChessDB found at this path" |
| Workers | 1..cores | Slider prevents invalid |
| Depth | 1..99 | Slider prevents invalid |
| MultiPV | 1..10 | Slider prevents invalid |
| Chess.com username | non-empty alphanumeric | "Invalid username format" |
| Probability cutoff | 0.001..0.1 | "Must be between 0.1% and 10%" |

---

## Edge Cases

### 1. Settings changed while generation is running

**Solution:** Engine settings changes (workers, depth) are queued and applied
after current generation completes. Show toast: "Settings will apply after
generation finishes."

### 2. Database path invalid after move/unmount

**Solution:** On app start, validate persisted paths. If invalid, disable
CdbDirect and show warning on next settings open: "Database path no longer
accessible."

### 3. Lichess token expired

**Solution:** `LichessAuthService` already handles refresh. Settings screen
shows "Connected" / "Token expired — [Reconnect]" based on auth state.

---

## Testing Strategy

| Test | Verifies |
|------|----------|
| Set value → restart app → value persisted | SharedPreferences round-trip |
| Invalid path → error shown, not saved | Validation works |
| Reset all → defaults restored | Reset button works |
| Change engine settings → EngineSettings notifier fires | Live sync |
| Open settings during generation → engine section shows warning | Non-destructive |

---

## What Gets Removed

- **Actions tab** (tab 7): Its content (EvalDatabaseSettingsPanel) moves to
  Settings screen. The "Train Repertoire" action moves to app bar. The "Import
  PGN" action moves to a menu on the PGN editor.
- **EngineSettings gear dialog** in UnifiedEnginePane: Quick access remains
  (subset of engine settings) but full config lives in Settings screen.
- **TrainingSettings tab** in Trainer: Link to full Settings screen, keep
  inline quick-settings for session-specific toggles (auto-next, etc.).
