/// Persistent settings for offline ChessDB database paths, and for the
/// on-demand expectimax probes that read them.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/safe_change_notifier.dart';

/// Process-wide singleton; widgets listen to it like [EngineSettings].
class EvalDatabaseSettings extends ChangeNotifier with SafeChangeNotifier {
  EvalDatabaseSettings._();
  static final EvalDatabaseSettings instance = EvalDatabaseSettings._();

  static const _keyEnableCdbDirect = 'eval.cdbdirect.enabled';
  static const _keyCdbDirectPath = 'eval.cdbdirect.path';
  static const _keyCdbDirectReadAhead = 'eval.cdbdirect.read_ahead';
  static const _keyEnableLichessEvals = 'eval.lichess.enabled';
  static const _keyLichessEvalsPath = 'eval.lichess.path';
  static const _keyChessDbApiForExpectimax = 'expectimax.chessdb_api';
  static const _keyExpectimaxProbePlies = 'expectimax.probe_plies';

  /// Half-moves an on-demand expectimax probe explores unless the user picks
  /// another depth in the pane.
  static const int defaultExpectimaxProbePlies = 12;
  static const int minExpectimaxProbePlies = 2;
  static const int maxExpectimaxProbePlies = 60;

  bool _loaded = false;
  bool _enableCdbDirect = false;
  String _cdbDirectPath = '';
  bool _cdbDirectReadAhead = false;
  bool _enableLichessEvals = false;
  String _lichessEvalsPath = '';
  bool _chessDbApiForExpectimax = false;
  int _expectimaxProbePlies = defaultExpectimaxProbePlies;

  bool get isLoaded => _loaded;
  bool get enableCdbDirect => _enableCdbDirect;
  String get cdbDirectPath => _cdbDirectPath;
  bool get cdbDirectReadAhead => _cdbDirectReadAhead;

  /// Whether the Lichess cloud-evaluation store is consulted during a build.
  bool get enableLichessEvals => _enableLichessEvals;

  /// Directory holding the built store (`evals.bin` and friends).
  String get lichessEvalsPath => _lichessEvalsPath;

  /// Whether an on-demand expectimax probe may query the chessdb.cn API.
  /// Off by default: a probe from a busy position burns through the daily
  /// quota in minutes, and the local dump or the engine answer just as well.
  bool get chessDbApiForExpectimax => _chessDbApiForExpectimax;

  /// Depth of an on-demand expectimax probe, in half-moves.
  int get expectimaxProbePlies => _expectimaxProbePlies;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _enableCdbDirect = prefs.getBool(_keyEnableCdbDirect) ?? false;
    _cdbDirectPath = prefs.getString(_keyCdbDirectPath) ?? '';
    _cdbDirectReadAhead = prefs.getBool(_keyCdbDirectReadAhead) ?? false;
    _enableLichessEvals = prefs.getBool(_keyEnableLichessEvals) ?? false;
    _lichessEvalsPath = prefs.getString(_keyLichessEvalsPath) ?? '';
    _chessDbApiForExpectimax =
        prefs.getBool(_keyChessDbApiForExpectimax) ?? false;
    _expectimaxProbePlies =
        prefs.getInt(_keyExpectimaxProbePlies) ?? defaultExpectimaxProbePlies;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setChessDbApiForExpectimax(bool value) => _update(
    _keyChessDbApiForExpectimax,
    value,
    () => _chessDbApiForExpectimax,
    (v) => _chessDbApiForExpectimax = v,
  );

  Future<void> setExpectimaxProbePlies(int value) => _update(
    _keyExpectimaxProbePlies,
    value.clamp(minExpectimaxProbePlies, maxExpectimaxProbePlies),
    () => _expectimaxProbePlies,
    (v) => _expectimaxProbePlies = v,
  );

  Future<void> setEnableCdbDirect(bool value) => _update(
    _keyEnableCdbDirect,
    value,
    () => _enableCdbDirect,
    (v) => _enableCdbDirect = v,
  );

  Future<void> setCdbDirectPath(String value) => _update(
    _keyCdbDirectPath,
    value,
    () => _cdbDirectPath,
    (v) => _cdbDirectPath = v,
  );

  Future<void> setCdbDirectReadAhead(bool value) => _update(
    _keyCdbDirectReadAhead,
    value,
    () => _cdbDirectReadAhead,
    (v) => _cdbDirectReadAhead = v,
  );

  Future<void> setEnableLichessEvals(bool value) => _update(
    _keyEnableLichessEvals,
    value,
    () => _enableLichessEvals,
    (v) => _enableLichessEvals = v,
  );

  Future<void> setLichessEvalsPath(String value) => _update(
    _keyLichessEvalsPath,
    value,
    () => _lichessEvalsPath,
    (v) => _lichessEvalsPath = v,
  );

  /// Store [value] under [key] when it differs from what [read] returns:
  /// listeners hear about it at once, the preference is written after.
  Future<void> _update<T extends Object>(
    String key,
    T value,
    T Function() read,
    void Function(T) assign,
  ) async {
    if (read() == value) return;
    assign(value);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await switch (value) {
      final bool v => prefs.setBool(key, v),
      final int v => prefs.setInt(key, v),
      final String v => prefs.setString(key, v),
      _ => throw ArgumentError.value(value, 'value', 'unsupported type'),
    };
  }

  Future<void> resetToDefaults() async {
    _enableCdbDirect = false;
    _cdbDirectPath = '';
    _cdbDirectReadAhead = false;
    _enableLichessEvals = false;
    _lichessEvalsPath = '';
    _chessDbApiForExpectimax = false;
    _expectimaxProbePlies = defaultExpectimaxProbePlies;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnableCdbDirect, false);
    await prefs.setString(_keyCdbDirectPath, '');
    await prefs.setBool(_keyCdbDirectReadAhead, false);
    await prefs.setBool(_keyEnableLichessEvals, false);
    await prefs.setString(_keyLichessEvalsPath, '');
    await prefs.setBool(_keyChessDbApiForExpectimax, false);
    await prefs.setInt(_keyExpectimaxProbePlies, defaultExpectimaxProbePlies);
  }
}
