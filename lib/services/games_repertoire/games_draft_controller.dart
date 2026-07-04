/// Session state for a build-from-games draft (fetch games → build tree →
/// review inline in the Lines/Draft tab).
///
/// Extracted from RepertoireScreen so the async build flow is testable and
/// the screen only renders the state.
library;

import 'package:flutter/foundation.dart';

import '../../models/move_tree.dart';
import '../../widgets/games_repertoire/games_source_form.dart';
import '../games_library/games_library_service.dart';
import '../unified_analysis_builder.dart';
import 'games_draft.dart';

class GamesDraftController extends ChangeNotifier {
  GamesDraftController({GamesLibraryService? gamesLibrary})
      : _gamesLibrary = gamesLibrary ?? GamesLibraryService();

  final GamesLibraryService _gamesLibrary;

  GamesDraft? _draft;
  bool _building = false;
  bool _isWhite = true;
  String _sourceLabel = '';
  String _progress = '';

  GamesDraft? get draft => _draft;
  bool get isBuilding => _building;
  bool get isWhite => _isWhite;
  String get sourceLabel => _sourceLabel;
  String get progress => _progress;

  /// A draft session occupies the Lines/Draft tab while building or reviewing.
  bool get isActive => _draft != null || _building;

  /// Fetch games per [config] and build a draft tree classified against
  /// [repertoire]. Returns an error message to show the user, or null on
  /// success. No-ops if a build is already running.
  Future<String?> build({
    required GamesSourceConfig config,
    required MoveTree repertoire,
  }) async {
    if (_building) return null;

    _draft = null;
    _building = true;
    _isWhite = config.isWhite;
    _sourceLabel = config.username;
    _progress = 'Starting…';
    notifyListeners();

    try {
      final records = await _gamesLibrary.getGames(
        platform: config.platform,
        username: config.username,
        selection: config.selection,
        onProgress: _setProgress,
      );
      if (records.isEmpty) {
        _building = false;
        notifyListeners();
        return 'No games found for "${config.username}".';
      }

      _setProgress('Building tree from ${records.length} games…');
      final (_, tree) = await UnifiedAnalysisBuilder.buildInIsolate(
        pgnList: records.map((r) => r.pgn).toList(),
        username: config.username,
        isWhite: config.isWhite,
        strictPlayerMatching: false,
      );

      _draft = GamesDraft.against(
        tree: tree,
        isWhite: config.isWhite,
        repertoire: repertoire,
      );
      _building = false;
      notifyListeners();
      return null;
    } catch (e) {
      _building = false;
      notifyListeners();
      return 'Could not build draft: $e';
    }
  }

  void _setProgress(String message) {
    _progress = message;
    notifyListeners();
  }

  void close() {
    _draft = null;
    _building = false;
    notifyListeners();
  }
}
