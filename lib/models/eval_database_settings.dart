/// Persistent settings for offline ChessDB database paths, and for the
/// on-demand expectimax probes that read them.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/safe_change_notifier.dart';

class EvalDatabaseSettings extends ChangeNotifier with SafeChangeNotifier {
  EvalDatabaseSettings._();
  static final EvalDatabaseSettings instance = EvalDatabaseSettings._();

  static const _keyEnableCdbDirect = 'eval.cdbdirect.enabled';
  static const _keyCdbDirectPath = 'eval.cdbdirect.path';
  static const _keyCdbDirectReadAhead = 'eval.cdbdirect.read_ahead';
  static const _keyChessDbApiForExpectimax = 'expectimax.chessdb_api';
  static const _keyExpectimaxProbePlies = 'expectimax.probe_plies';

  /// Half-moves an on-demand expectimax probe explores unless the user picks
  /// another depth in the pane.
  static const int defaultExpectimaxProbePlies = 12;

  bool _loaded = false;
  bool _enableCdbDirect = false;
  String _cdbDirectPath = '';
  bool _cdbDirectReadAhead = false;
  bool _chessDbApiForExpectimax = false;
  int _expectimaxProbePlies = defaultExpectimaxProbePlies;

  bool get isLoaded => _loaded;
  bool get enableCdbDirect => _enableCdbDirect;
  String get cdbDirectPath => _cdbDirectPath;
  bool get cdbDirectReadAhead => _cdbDirectReadAhead;

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
    _chessDbApiForExpectimax =
        prefs.getBool(_keyChessDbApiForExpectimax) ?? false;
    _expectimaxProbePlies =
        prefs.getInt(_keyExpectimaxProbePlies) ?? defaultExpectimaxProbePlies;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setChessDbApiForExpectimax(bool value) async {
    if (_chessDbApiForExpectimax == value) return;
    _chessDbApiForExpectimax = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyChessDbApiForExpectimax, value);
  }

  Future<void> setExpectimaxProbePlies(int value) async {
    final clamped = value.clamp(2, 60);
    if (_expectimaxProbePlies == clamped) return;
    _expectimaxProbePlies = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyExpectimaxProbePlies, clamped);
  }

  Future<void> setEnableCdbDirect(bool value) async {
    if (_enableCdbDirect == value) return;
    _enableCdbDirect = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnableCdbDirect, value);
  }

  Future<void> setCdbDirectPath(String value) async {
    if (_cdbDirectPath == value) return;
    _cdbDirectPath = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCdbDirectPath, value);
  }

  Future<void> setCdbDirectReadAhead(bool value) async {
    if (_cdbDirectReadAhead == value) return;
    _cdbDirectReadAhead = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyCdbDirectReadAhead, value);
  }

  Future<void> resetToDefaults() async {
    _enableCdbDirect = false;
    _cdbDirectPath = '';
    _cdbDirectReadAhead = false;
    _chessDbApiForExpectimax = false;
    _expectimaxProbePlies = defaultExpectimaxProbePlies;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnableCdbDirect, false);
    await prefs.setString(_keyCdbDirectPath, '');
    await prefs.setBool(_keyCdbDirectReadAhead, false);
    await prefs.setBool(_keyChessDbApiForExpectimax, false);
    await prefs.setInt(_keyExpectimaxProbePlies, defaultExpectimaxProbePlies);
  }
}
