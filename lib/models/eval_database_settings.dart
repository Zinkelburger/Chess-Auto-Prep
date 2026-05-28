/// Persistent settings for offline ChessDB database paths.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class EvalDatabaseSettings extends ChangeNotifier {
  EvalDatabaseSettings._();
  static final EvalDatabaseSettings instance = EvalDatabaseSettings._();

  static const _keyEnableCdbDirect = 'eval.cdbdirect.enabled';
  static const _keyCdbDirectPath = 'eval.cdbdirect.path';
  static const _keyCdbDirectReadAhead = 'eval.cdbdirect.read_ahead';

  bool _loaded = false;
  bool _enableCdbDirect = false;
  String _cdbDirectPath = '';
  bool _cdbDirectReadAhead = false;

  bool get isLoaded => _loaded;
  bool get enableCdbDirect => _enableCdbDirect;
  String get cdbDirectPath => _cdbDirectPath;
  bool get cdbDirectReadAhead => _cdbDirectReadAhead;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _enableCdbDirect = prefs.getBool(_keyEnableCdbDirect) ?? false;
    _cdbDirectPath = prefs.getString(_keyCdbDirectPath) ?? '';
    _cdbDirectReadAhead = prefs.getBool(_keyCdbDirectReadAhead) ?? false;
    _loaded = true;
    notifyListeners();
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
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnableCdbDirect, false);
    await prefs.setString(_keyCdbDirectPath, '');
    await prefs.setBool(_keyCdbDirectReadAhead, false);
  }
}
