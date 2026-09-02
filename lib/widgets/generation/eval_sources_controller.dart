/// The editable state behind [EvalSourcesSection].
///
/// The section is a collapsed expander for most of a session, and the form
/// reads its values at Start — so the values cannot live in the widget's
/// [State], which exists only while the expander is open. They live here,
/// owned by the form, and the section renders them.
library;

import 'package:flutter/widgets.dart';

import '../../models/eval_database_settings.dart';
import '../../services/eval/chessdb_api_provider.dart';
import '../../services/generation/generation_config.dart';
import '../../utils/safe_change_notifier.dart';

/// Field defaults, shared by the initial text and the parse fallbacks so the
/// two cannot disagree.
const int _defaultDailyQuota = 5000;
const int _defaultConcurrency = 2;

/// Eval-source settings for one generation run: which lookup sources the
/// build may consult before it falls through to Stockfish.
///
/// Pairs [applyConfig] with [applyTo] — the two halves of the round trip a
/// config makes through the form, deliberately kept in one file so a knob
/// cannot be seeded without being read back, or the reverse.
/// `generation_config_form_roundtrip_test.dart` pins that pairing.
class EvalSourcesController extends ChangeNotifier with SafeChangeNotifier {
  /// Path of the local ChessDB SQLite slice. Only the picker writes it, but
  /// it is a controller because the read-only field displays it.
  final TextEditingController localChessDbPathField = TextEditingController();
  final TextEditingController dailyQuotaField = TextEditingController(
    text: '$_defaultDailyQuota',
  );
  final TextEditingController concurrencyField = TextEditingController(
    text: '$_defaultConcurrency',
  );

  /// Minimum search depth an external hit must carry. Empty means "no
  /// floor", which is the one value whose display is not its number.
  final TextEditingController minEvalDepthField = TextEditingController();

  bool _batchEvalLookups = false;
  bool _enableLocalChessDb = false;
  // On by default: the ChessDB cloud is a fallback consulted *before* the
  // engine, so it only speeds things up when no local dump is configured, and
  // the provider now backs off on server rate-limiting. The user can turn it
  // off. (See docs/REPERTOIRE_PLANNING.md, 'Eval sources when the user has no
  // database'.)
  bool _enableChessDbApi = true;
  bool _enableExtEvalSubtreeSkip = true;
  bool? _localChessDbFileValid;
  int _apiUsedToday = 0;
  int _apiQuotaLimit = _defaultDailyQuota;

  bool get batchEvalLookups => _batchEvalLookups;
  set batchEvalLookups(bool value) =>
      _set(_batchEvalLookups, value, (v) => _batchEvalLookups = v);

  bool get enableLocalChessDb => _enableLocalChessDb;
  set enableLocalChessDb(bool value) =>
      _set(_enableLocalChessDb, value, (v) => _enableLocalChessDb = v);

  bool get enableChessDbApi => _enableChessDbApi;
  set enableChessDbApi(bool value) =>
      _set(_enableChessDbApi, value, (v) => _enableChessDbApi = v);

  bool get enableExtEvalSubtreeSkip => _enableExtEvalSubtreeSkip;
  set enableExtEvalSubtreeSkip(bool value) => _set(
    _enableExtEvalSubtreeSkip,
    value,
    (v) => _enableExtEvalSubtreeSkip = v,
  );

  /// Whether the configured file was checked and holds a ChessDB eval table.
  /// Null while unknown — a path seeded from a config has not been opened.
  bool? get localChessDbFileValid => _localChessDbFileValid;

  String get localChessDbPath => localChessDbPathField.text.trim();

  int get chessDbApiDailyQuota =>
      (int.tryParse(dailyQuotaField.text.trim()) ?? _defaultDailyQuota).clamp(
        1,
        50000,
      );

  int get chessDbApiConcurrency =>
      (int.tryParse(concurrencyField.text.trim()) ?? _defaultConcurrency).clamp(
        1,
        16,
      );

  /// ChessDB API requests spent today, and the ceiling they count against.
  int get apiUsedToday => _apiUsedToday;
  int get apiQuotaLimit => _apiQuotaLimit;

  /// The depth floor for external eval hits, where 0 means "no floor".
  ///
  /// An unparseable entry falls back to [engineEvalDepth] — asking for at
  /// least what the engine would have produced — rather than to 0, which
  /// would silently accept every shallow hit.
  int minAcceptableEvalDepth({required int engineEvalDepth}) {
    final raw = minEvalDepthField.text.trim();
    if (raw.isEmpty) return 0;
    return int.tryParse(raw) ?? engineEvalDepth;
  }

  /// Records a file the user picked, and whether it validated.
  ///
  /// Arrives after a modal picker and a file read, either of which can outlive
  /// the form, so it checks [isDisposed] before touching the fields.
  void setLocalChessDbFile(String path, {required bool valid}) {
    if (isDisposed) return;
    localChessDbPathField.text = path;
    _localChessDbFileValid = valid;
    if (valid) _enableLocalChessDb = true;
    notifyListeners();
  }

  void clearLocalChessDbFile() {
    localChessDbPathField.clear();
    _localChessDbFileValid = null;
    notifyListeners();
  }

  /// Seeds every control from [config] — the exact inverse of [applyTo].
  ///
  /// Without this the section was write-only from the config's point of view:
  /// it published eight fields into every built config but had no way to be
  /// told what they were, so reopening the form on a saved config or a preset
  /// silently reset all eight to the defaults above.
  void applyConfig(TreeBuildConfig config) {
    _batchEvalLookups = config.batchEvalLookups;
    _enableLocalChessDb = config.enableLocalChessDb;
    localChessDbPathField.text = config.localChessDbPath;
    // Re-validated lazily; the path came from a config that was built with
    // it, not from the picker, so nothing has checked this file yet.
    _localChessDbFileValid = null;
    _enableChessDbApi = config.enableChessDbApi;
    dailyQuotaField.text = config.chessDbApiDailyQuota.toString();
    concurrencyField.text = config.chessDbApiConcurrency.toString();
    _enableExtEvalSubtreeSkip = config.enableExtEvalSubtreeSkip;
    minEvalDepthField.text = config.minAcceptableEvalDepth > 0
        ? config.minAcceptableEvalDepth.toString()
        : '';
    notifyListeners();
  }

  /// Writes what the controls describe onto [config] — the inverse of
  /// [applyConfig].
  ///
  /// The cdb-direct trio and the Lichess pair are not ours to edit: they are
  /// owned by app settings ([databases]), and cdb-direct is additionally
  /// gated on a runtime probe for the native reader ([cdbDirectAvailable]),
  /// so a config cannot dictate them and neither can this section. They are
  /// written here because they belong to the same lookup chain the section
  /// describes — and because nothing else writes them: while these two lines
  /// were missing, `enableLichessEvals` was false in every build the form
  /// started, so the store, its provider and its stats counters were
  /// unreachable no matter what the user had downloaded or switched on.
  TreeBuildConfig applyTo(
    TreeBuildConfig config, {
    required EvalDatabaseSettings databases,
    required bool cdbDirectAvailable,
    required int engineEvalDepth,
  }) {
    return config.copyWith(
      enableCdbDirect: cdbDirectAvailable && databases.enableCdbDirect,
      cdbDirectPath: cdbDirectAvailable ? databases.cdbDirectPath : '',
      cdbDirectReadAhead: cdbDirectAvailable && databases.cdbDirectReadAhead,
      batchEvalLookups: cdbDirectAvailable && _batchEvalLookups,
      enableLichessEvals:
          databases.enableLichessEvals && databases.lichessEvalsPath.isNotEmpty,
      lichessEvalsPath: databases.lichessEvalsPath,
      enableLocalChessDb: _enableLocalChessDb,
      localChessDbPath: localChessDbPath,
      enableChessDbApi: _enableChessDbApi,
      chessDbApiDailyQuota: chessDbApiDailyQuota,
      chessDbApiConcurrency: chessDbApiConcurrency,
      enableExtEvalSubtreeSkip: _enableExtEvalSubtreeSkip,
      minAcceptableEvalDepth: minAcceptableEvalDepth(
        engineEvalDepth: engineEvalDepth,
      ),
    );
  }

  /// Reads today's spend from the provider's own store, for the usage line.
  Future<void> refreshApiUsage() async {
    final api = ChessDbApiProvider(dailyQuota: chessDbApiDailyQuota);
    await api.init();
    if (isDisposed) return;
    _apiUsedToday = api.usedToday;
    _apiQuotaLimit = api.quotaLimit;
    notifyListeners();
  }

  /// A build is starting: the usage line counts this run, from zero.
  void resetApiUsageForBuild(int quotaLimit) {
    _apiQuotaLimit = quotaLimit;
    _apiUsedToday = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    localChessDbPathField.dispose();
    dailyQuotaField.dispose();
    concurrencyField.dispose();
    minEvalDepthField.dispose();
    super.dispose();
  }

  /// Assigns through [assign] and notifies, unless nothing changed.
  void _set<T>(T current, T next, ValueSetter<T> assign) {
    if (current == next) return;
    assign(next);
    notifyListeners();
  }
}
