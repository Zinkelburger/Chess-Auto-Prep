/// Persisted shape of the repertoire builder's wide layout: how much width
/// the board takes, how wide the Lines and outline side panels are and
/// whether each is collapsed to a strip, and how tall the database pane is.
///
/// These are the layout the user arranges and expects to find again after a
/// restart, so they are worth owning in one place — previously they were
/// loose fields, preference keys and `SharedPreferences` round-trips
/// scattered through the screen's state class, with the sizing arithmetic
/// inlined in a `LayoutBuilder` where it could not be checked.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/board_size.dart';
import '../../../utils/log.dart';
import '../../../utils/safe_change_notifier.dart';

class RepertoireLayoutPrefs extends ChangeNotifier with SafeChangeNotifier {
  static const String collapsedKey = 'repertoire.lines_panel_collapsed';
  static const String widthKey = 'repertoire.lines_panel_width';
  static const String boardSizeKey = 'repertoire.board_size';
  static const String outlineCollapsedKey =
      'repertoire.outline_panel_collapsed';
  static const String outlineWidthKey = 'repertoire.outline_panel_width';
  static const String databaseHeightKey = 'repertoire.database_height';

  /// Narrowest the Lines side panel may be dragged before it is worth
  /// collapsing instead.
  static const double minPanelWidth = 220.0;

  /// A side panel may take at most this share of the body's width, so the
  /// PGN editor beside it stays usable.
  static const double _maxPanelShare = 0.45;

  /// Proportional default for the Lines panel, and its bounds.
  static const double _defaultLinesPanelShare = 0.24;
  static const double _minDefaultLinesPanelWidth = 260.0;
  static const double _maxDefaultLinesPanelWidth = 400.0;

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

  bool _linesPanelCollapsed = false;
  double? _linesPanelWidth;
  BoardSize _boardSize = BoardSize.large;
  bool _outlinePanelCollapsed = false;
  double? _outlinePanelWidth;
  double? _databaseHeight;

  bool get linesPanelCollapsed => _linesPanelCollapsed;

  /// User-dragged panel width, or null while it still follows the
  /// proportional default. See [resolveLinesPanelWidth].
  double? get linesPanelWidth => _linesPanelWidth;

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
      _linesPanelCollapsed = prefs.getBool(collapsedKey) ?? false;
      _linesPanelWidth = prefs.getDouble(widthKey);
      _boardSize = BoardSize.fromName(prefs.getString(boardSizeKey));
      _outlinePanelCollapsed = prefs.getBool(outlineCollapsedKey) ?? false;
      _outlinePanelWidth = prefs.getDouble(outlineWidthKey);
      _databaseHeight = prefs.getDouble(databaseHeightKey);
      notifyListeners();
    } catch (e) {
      log.w('Failed to load layout prefs', name: _logName, error: e);
    }
  }

  // ── Lines panel ──────────────────────────────────────────────────────────

  Future<void> setLinesPanelCollapsed(bool collapsed) async {
    if (_linesPanelCollapsed == collapsed) return;
    _linesPanelCollapsed = collapsed;
    notifyListeners();
    await _write((prefs) => prefs.setBool(collapsedKey, collapsed));
  }

  Future<void> toggleLinesPanelCollapsed() =>
      setLinesPanelCollapsed(!_linesPanelCollapsed);

  /// Width update from an in-flight drag: repaints, but does not touch disk.
  /// Call [saveLinesPanelWidth] when the drag ends.
  void dragLinesPanelWidth(double width) {
    if (_linesPanelWidth == width) return;
    _linesPanelWidth = width;
    notifyListeners();
  }

  Future<void> saveLinesPanelWidth() async {
    final width = _linesPanelWidth;
    if (width == null) return;
    await _write((prefs) => prefs.setDouble(widthKey, width));
  }

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

  static double _clampDatabaseHeight(double height, double availableHeight) =>
      height.clamp(
        _minDatabaseHeight,
        math.max(_minDatabaseHeight, availableHeight * _maxDatabaseShare),
      );

  // ── Layout arithmetic ────────────────────────────────────────────────────

  /// Widest the Lines panel may be for a body [availableWidth] — a little
  /// under half, so the PGN editor beside it stays usable.
  static double maxLinesPanelWidth(double availableWidth) =>
      math.max(minPanelWidth, availableWidth * _maxPanelShare);

  /// The panel's width: the user's dragged width when they have set one, a
  /// proportional default otherwise, always inside
  /// [minPanelWidth]..[maxLinesPanelWidth].
  double resolveLinesPanelWidth(double availableWidth) {
    final defaultWidth = (availableWidth * _defaultLinesPanelShare).clamp(
      _minDefaultLinesPanelWidth,
      _maxDefaultLinesPanelWidth,
    );
    return _clampPanelWidth(_linesPanelWidth ?? defaultWidth, availableWidth);
  }

  /// The outline column's width: dragged width if set, else a proportional
  /// default, inside [minPanelWidth]..[maxLinesPanelWidth].
  double resolveOutlinePanelWidth(double availableWidth) {
    final defaultWidth = (availableWidth * _defaultOutlinePanelShare).clamp(
      _minDefaultOutlinePanelWidth,
      _maxDefaultOutlinePanelWidth,
    );
    return _clampPanelWidth(_outlinePanelWidth ?? defaultWidth, availableWidth);
  }

  static double _clampPanelWidth(double width, double availableWidth) =>
      width.clamp(minPanelWidth, maxLinesPanelWidth(availableWidth)).toDouble();

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
