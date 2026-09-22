/// Persisted Builder layout: board size, outline width/collapse, and analysis
/// dock height/collapse. The outline is the only horizontally resizable panel.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/board_size.dart';
import '../../../utils/log.dart';
import '../../../utils/safe_change_notifier.dart';

class RepertoireLayoutPrefs extends ChangeNotifier with SafeChangeNotifier {
  // Preserve the existing preference key when naming the active dock.
  static const String analysisCollapsedKey = 'repertoire.lines_panel_collapsed';
  static const String boardSizeKey = 'repertoire.board_size';
  static const String outlineCollapsedKey =
      'repertoire.outline_panel_collapsed';
  static const String outlineWidthKey = 'repertoire.outline_panel_width';
  static const String databaseHeightKey = 'repertoire.database_height';

  /// Shared with the planner's own copy of the Database pane, which has
  /// always written this key.
  static const String databaseSourceKey = 'repertoire.reference_source';

  /// Which source the Database pane shows: 0 Repertoire, 1 Opening explorer,
  /// 2 Local PGN, 3 Engine evals, 4 ChessDB.
  static const int defaultDatabaseSource = 3;
  static const int maxDatabaseSource = 4;

  /// Narrowest the outline panel may be dragged before it is worth
  /// collapsing instead.
  static const double minPanelWidth = 220.0;

  /// A side panel may take at most this share of the body's width, so the
  /// PGN editor beside it stays usable.
  static const double _maxPanelShare = 0.45;

  /// Proportional default for the outline column, and its bounds.
  static const double _defaultOutlinePanelShare = 0.18;
  static const double _minDefaultOutlinePanelWidth = 220.0;
  static const double _maxDefaultOutlinePanelWidth = 280.0;

  /// The board can never take more than half the body's width.
  static const double _maxBoardShare = 0.5;

  /// The database pane: never shorter than this, never taller than this
  /// share of the body, and a proportional default in between.
  static const double _minDatabaseHeight = 200.0;
  static const double _defaultDatabaseShare = 0.34;
  static const double _maxDatabaseShare = 0.55;

  static const String _logName = 'RepertoireLayout';

  bool _analysisCollapsed = false;
  BoardSize _boardSize = BoardSize.large;
  bool _outlinePanelCollapsed = false;
  double? _outlinePanelWidth;
  double? _databaseHeight;
  int _databaseSource = defaultDatabaseSource;

  /// Which source the Database pane opens on. Restored at startup: picking a
  /// source is a choice about how you work, not a per-session accident.
  int get databaseSource => _databaseSource;

  bool get analysisCollapsed => _analysisCollapsed;

  BoardSize get boardSize => _boardSize;

  bool get outlinePanelCollapsed => _outlinePanelCollapsed;

  /// User-dragged outline width, or null while it follows the default. See
  /// [resolveOutlinePanelWidth].
  double? get outlinePanelWidth => _outlinePanelWidth;

  /// Reads every knob. A failed read leaves the defaults in place: a broken
  /// preference store should cost the user their layout, not the screen.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _analysisCollapsed = prefs.getBool(analysisCollapsedKey) ?? false;
      _boardSize = BoardSize.fromName(prefs.getString(boardSizeKey));
      _outlinePanelCollapsed = prefs.getBool(outlineCollapsedKey) ?? false;
      _outlinePanelWidth = prefs.getDouble(outlineWidthKey);
      _databaseHeight = prefs.getDouble(databaseHeightKey);
      _databaseSource = _clampDatabaseSource(prefs.getInt(databaseSourceKey));
      notifyListeners();
    } catch (e) {
      log.w('Failed to load layout prefs', name: _logName, error: e);
    }
  }

  // ── Analysis dock ──────────────────────────────────────────────────────────

  Future<void> setAnalysisCollapsed(bool collapsed) async {
    if (_analysisCollapsed == collapsed) return;
    _analysisCollapsed = collapsed;
    notifyListeners();
    await _write((prefs) => prefs.setBool(analysisCollapsedKey, collapsed));
  }

  Future<void> toggleAnalysisCollapsed() =>
      setAnalysisCollapsed(!_analysisCollapsed);

  // ── Outline panel ────────────────────────────────────────────────────────

  Future<void> setOutlinePanelCollapsed(bool collapsed) async {
    if (_outlinePanelCollapsed == collapsed) return;
    _outlinePanelCollapsed = collapsed;
    notifyListeners();
    await _write((prefs) => prefs.setBool(outlineCollapsedKey, collapsed));
  }

  Future<void> toggleOutlinePanelCollapsed() =>
      setOutlinePanelCollapsed(!_outlinePanelCollapsed);

  void dragOutlinePanelWidth(double width) {
    if (_outlinePanelWidth == width) return;
    _outlinePanelWidth = width;
    notifyListeners();
  }

  Future<void> saveOutlinePanelWidth() async {
    final width = _outlinePanelWidth;
    if (width == null) return;
    await _write((prefs) => prefs.setDouble(outlineWidthKey, width));
  }

  // ── Board ────────────────────────────────────────────────────────────────

  Future<void> setBoardSize(BoardSize size) async {
    if (_boardSize == size) return;
    _boardSize = size;
    notifyListeners();
    await _write((prefs) => prefs.setString(boardSizeKey, size.name));
  }

  // ── Database pane ────────────────────────────────────────────────────────

  double resolveDatabaseHeight(double availableHeight) => _clampDatabaseHeight(
    _databaseHeight ?? availableHeight * _defaultDatabaseShare,
    availableHeight,
  );

  void dragDatabaseHeight(double value, double availableHeight) {
    _databaseHeight = _clampDatabaseHeight(value, availableHeight);
    notifyListeners();
  }

  Future<void> saveDatabaseHeight() async {
    final height = _databaseHeight;
    if (height == null) return;
    await _write((prefs) => prefs.setDouble(databaseHeightKey, height));
  }

  Future<void> setDatabaseSource(int source) async {
    final next = _clampDatabaseSource(source);
    if (_databaseSource == next) return;
    _databaseSource = next;
    notifyListeners();
    await _write((prefs) => prefs.setInt(databaseSourceKey, next));
  }

  /// An unset, corrupt or out-of-range key falls back to the default rather
  /// than indexing the source list out of bounds.
  static int _clampDatabaseSource(int? source) =>
      source == null || source < 0 || source > maxDatabaseSource
      ? defaultDatabaseSource
      : source;

  static double _clampDatabaseHeight(double height, double availableHeight) =>
      height.clamp(
        _minDatabaseHeight,
        math.max(_minDatabaseHeight, availableHeight * _maxDatabaseShare),
      );

  // ── Layout arithmetic ────────────────────────────────────────────────────

  /// Widest the outline panel may be for a body [availableWidth] — a little
  /// under half, so the PGN editor beside it stays usable.
  static double maxOutlinePanelWidth(double availableWidth) =>
      math.max(minPanelWidth, availableWidth * _maxPanelShare);

  /// The outline column's width: dragged width if set, else a proportional
  /// default, inside [minPanelWidth]..[maxOutlinePanelWidth].
  double resolveOutlinePanelWidth(double availableWidth) {
    final defaultWidth = (availableWidth * _defaultOutlinePanelShare).clamp(
      _minDefaultOutlinePanelWidth,
      _maxDefaultOutlinePanelWidth,
    );
    return _clampPanelWidth(_outlinePanelWidth ?? defaultWidth, availableWidth);
  }

  static double _clampPanelWidth(double width, double availableWidth) => width
      .clamp(minPanelWidth, maxOutlinePanelWidth(availableWidth))
      .toDouble();

  /// Width of the board column.
  ///
  /// The board is square, so the largest one that fits is bounded by the
  /// body's height — and by half its width, so the board can never crowd the
  /// tools out entirely. [BoardSize] then scales that natural size down.
  double boardZoneWidth({
    required double availableWidth,
    required double availableHeight,
  }) {
    final natural = availableHeight.clamp(0.0, availableWidth * _maxBoardShare);
    return (natural * _boardSize.widthFactor).clamp(0.0, natural).toDouble();
  }

  Future<void> _write(Future<void> Function(SharedPreferences) write) async {
    try {
      await write(await SharedPreferences.getInstance());
    } catch (e) {
      log.w('Failed to save layout prefs', name: _logName, error: e);
    }
  }
}
