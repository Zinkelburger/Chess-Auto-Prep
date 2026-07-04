/// Form state for the tactics import panel: text fields, debounced
/// validation, fetch mode, and persisted count/depth/cores preferences.
///
/// Owned by the tactics control panel; extracted so the form logic is
/// testable and the panel only renders it.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tactics_import_service.dart' show TacticsImportService;
import 'tactics_import_coordinator.dart';

class TacticsImportForm extends ChangeNotifier {
  TacticsImportForm({int defaultCores = 1})
      : coresText = TextEditingController(text: '$defaultCores');

  final TextEditingController lichessUser = TextEditingController();
  final TextEditingController chessComUser = TextEditingController();
  final TextEditingController fetchCount = TextEditingController(text: '20');
  final TextEditingController depthText = TextEditingController(text: '15');
  final TextEditingController coresText;

  TacticsImportMode fetchMode = TacticsImportMode.recent;
  DateTime? sinceDate;

  // Validation: *Valid tracks logical state (immediate), *Error is the
  // displayed red text (debounced so it doesn't flash while typing).
  bool depthValid = true;
  bool coresValid = true;
  String? depthError;
  String? coresError;
  Timer? _depthErrorTimer;
  Timer? _coresErrorTimer;

  bool _disposed = false;

  bool get fieldsValid => depthValid && coresValid;

  /// Parsed engine depth, clamped to the supported range.
  int get depth => (int.tryParse(depthText.text) ?? 15).clamp(1, 25);

  /// Parsed worker count, clamped to available cores.
  int get cores => (int.tryParse(coresText.text) ?? 1)
      .clamp(1, TacticsImportService.availableCores);

  /// Parsed recent-games fetch count.
  int get count => int.tryParse(fetchCount.text) ?? 20;

  String usernameFor(TacticsImportSource source) =>
      source == TacticsImportSource.lichess
          ? lichessUser.text.trim()
          : chessComUser.text.trim();

  /// Import params for [source] from the current form values.
  TacticsImportParams paramsFor(TacticsImportSource source) =>
      TacticsImportParams(
        username: usernameFor(source),
        mode: fetchMode,
        maxGames: fetchMode == TacticsImportMode.recent ? count : 200,
        since: fetchMode == TacticsImportMode.sinceDate ? sinceDate : null,
        depth: depth,
        cores: cores,
      );

  void setFetchMode(TacticsImportMode mode) {
    fetchMode = mode;
    notifyListeners();
  }

  void setSinceDate(DateTime? date) {
    sinceDate = date;
    notifyListeners();
  }

  void validateDepth(String value) {
    final v = int.tryParse(value);
    String? error;
    if (v == null) {
      error = 'Must be a number';
    } else if (v < 1 || v > 25) {
      error = 'Must be 1–25';
    }
    _depthErrorTimer = _applyFieldValidation(
      error: error,
      currentTimer: _depthErrorTimer,
      setValid: (valid) => depthValid = valid,
      setError: (e) => depthError = e,
    );
  }

  void validateCores(String value) {
    final v = int.tryParse(value);
    final max = TacticsImportService.availableCores;
    String? error;
    if (v == null) {
      error = 'Must be a number';
    } else if (v < 1 || v > max) {
      error = 'Must be 1–$max';
    }
    _coresErrorTimer = _applyFieldValidation(
      error: error,
      currentTimer: _coresErrorTimer,
      setValid: (valid) => coresValid = valid,
      setError: (e) => coresError = e,
    );
  }

  /// Applies a field validation result: updates logical validity immediately
  /// and clears the error when valid, then debounces showing the red error
  /// text. Returns the (possibly new) debounce timer to store for the field.
  Timer? _applyFieldValidation({
    required String? error,
    required Timer? currentTimer,
    required void Function(bool valid) setValid,
    required void Function(String? error) setError,
  }) {
    currentTimer?.cancel();
    setValid(error == null);
    if (error == null) setError(null);
    notifyListeners();
    if (error == null) return null;
    return Timer(const Duration(milliseconds: 500), () {
      if (_disposed) return;
      setError(error);
      notifyListeners();
    });
  }

  static const _prefImportCount = 'tactics_import.count';
  static const _prefImportDepth = 'tactics_import.depth';
  static const _prefImportCores = 'tactics_import.cores';

  /// Restore the last-used fetch count / depth / cores into the form fields.
  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    final count = prefs.getInt(_prefImportCount);
    final depth = prefs.getInt(_prefImportDepth);
    final cores = prefs.getInt(_prefImportCores);
    if (count != null) fetchCount.text = '$count';
    if (depth != null) depthText.text = '$depth';
    if (cores != null) coresText.text = '$cores';
  }

  /// Remember the current fetch count / depth / cores for next launch.
  Future<void> savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final count = int.tryParse(fetchCount.text);
    final depth = int.tryParse(depthText.text);
    final cores = int.tryParse(coresText.text);
    if (count != null) await prefs.setInt(_prefImportCount, count);
    if (depth != null) await prefs.setInt(_prefImportDepth, depth);
    if (cores != null) await prefs.setInt(_prefImportCores, cores);
  }

  @override
  void dispose() {
    _disposed = true;
    _depthErrorTimer?.cancel();
    _coresErrorTimer?.cancel();
    lichessUser.dispose();
    chessComUser.dispose();
    fetchCount.dispose();
    depthText.dispose();
    coresText.dispose();
    super.dispose();
  }
}
