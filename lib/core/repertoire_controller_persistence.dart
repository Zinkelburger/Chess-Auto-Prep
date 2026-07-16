// Part of repertoire_controller.dart: repertoire persistence lifecycle —
// setting/loading/reloading the repertoire file, writing metadata headers,
// building the opening tree, parsing lines, and PGN import. Same library as
// the controller, so private members resolve across the class/mixin boundary.
part of 'repertoire_controller.dart';

/// Repertoire file lifecycle for [RepertoireController]: load/reload, metadata
/// header writes, opening-tree build, line parsing, and PGN import. State
/// shared with the rest of the controller is declared abstract here and
/// implemented by the class; fields owned solely by this group live in the
/// mixin.
mixin _RepertoirePersistence on ChangeNotifier {
  // ── Host state (implemented by RepertoireController) ─────────────
  RepertoireMetadata? get _currentRepertoire;
  set _currentRepertoire(RepertoireMetadata? value);
  String? get _repertoirePgn;
  set _repertoirePgn(String? value);
  OpeningTree? get _openingTree;
  set _openingTree(OpeningTree? value);
  List<RepertoireLine> get _repertoireLines;
  set _repertoireLines(List<RepertoireLine> value);
  set _tree(MoveTree value);
  set _path(TreePath value);
  bool get _isRepertoireWhite;
  set _isRepertoireWhite(bool value);
  set _needsColorSelection(bool value);
  set _rootMoves(String value);
  String? get _loadError;
  set _loadError(String? value);
  bool get _isLoading;
  set _isLoading(bool value);
  RepertoireWriter get writer;
  RepertoireAuthoring get _authoring;
  List<String> get currentMoveSequence;
  void navigateToLineMove(List<String> fullPath, {int? targetIndex});
  void _navigateToRootPosition();
  String _movesToPgnMoveText(List<String> moves);

  // ── Repertoire lifecycle ─────────────────────────────────────────

  /// Sets a new repertoire and triggers loading.
  Future<void> setRepertoire(RepertoireMetadata repertoire) async {
    _currentRepertoire = repertoire;
    await loadRepertoire();
  }

  /// Writes the color header to the PGN file and reloads.
  Future<void> setRepertoireColor(bool isWhite) async {
    if (_currentRepertoire == null) return;
    final filePath = _currentRepertoire!.filePath;
    final storage = StorageFactory.instance;
    if (!await storage.fileExists(filePath)) return;

    final colorLabel = isWhite ? 'White' : 'Black';
    final existing = await storage.readFile(filePath);
    if (existing == null) return;
    final updated = _upsertMetadataComment(existing, '// Color:', colorLabel);
    await storage.writeFile(filePath, updated);
    _needsColorSelection = false;
    await loadRepertoire();
  }

  /// Sets the current move sequence as the root position and persists it.
  Future<void> setRootPosition() async {
    if (_currentRepertoire == null) return;
    final filePath = _currentRepertoire!.filePath;
    final storage = StorageFactory.instance;
    if (!await storage.fileExists(filePath)) return;

    final moveText = _movesToPgnMoveText(currentMoveSequence);
    _rootMoves = moveText;

    final existing = await storage.readFile(filePath);
    if (existing == null) return;
    final updated = _upsertMetadataComment(existing, '// Root:', moveText);
    await storage.writeFile(filePath, updated);
    notifyListeners();
  }

  /// Restores repertoire state from a PGN snapshot (used by undo).
  Future<void> restoreRepertoireFromPgn(
    String pgnContent, {
    List<String>? syncPath,
  }) async {
    _repertoirePgn = pgnContent.isEmpty ? null : pgnContent;
    await _buildOpeningTree();
    await _parseRepertoireLines();
    if (syncPath != null) {
      navigateToLineMove(syncPath);
    } else {
      _navigateToRootPosition();
    }
    notifyListeners();
  }

  /// (Re)loads the PGN content for the current repertoire.
  Future<void> loadRepertoire() async {
    if (_currentRepertoire == null) return;
    writer.clearUndoStack();
    _loadError = null;
    _setLoading(true);

    try {
      final filePath = _currentRepertoire!.filePath;
      final storage = StorageFactory.instance;

      if (await storage.fileExists(filePath)) {
        _repertoirePgn = await storage.readFile(filePath);

        _tree = MoveTree();
        _path = TreePath.empty;

        await _buildOpeningTree();
        await _parseRepertoireLines();
        _navigateToRootPosition();
      } else {
        _repertoirePgn = null;
        _openingTree = null;
        _repertoireLines = [];
        _tree = MoveTree();
        _path = TreePath.empty;
      }
    } catch (e) {
      _loadError = 'Failed to load repertoire: $e';
      debugPrint(_loadError);
      _repertoirePgn = null;
      _openingTree = null;
      _repertoireLines = [];
      _tree = MoveTree();
      _path = TreePath.empty;
    } finally {
      _setLoading(false);
    }
  }

  /// Parses repertoire lines for PGN browser.
  Future<void> _parseRepertoireLines() async {
    if (_repertoirePgn == null || _repertoirePgn!.isEmpty) {
      _repertoireLines = [];
      return;
    }

    try {
      final pgnContent = _repertoirePgn!;
      final color = _isRepertoireWhite ? 'white' : 'black';
      _repertoireLines = await compute(_parseRepertoireInIsolate, (
        pgn: pgnContent,
        color: color,
      ));
      debugPrint(
        'Parsed ${_repertoireLines.length} repertoire lines for PGN browser',
      );
    } catch (e) {
      debugPrint('Failed to parse repertoire lines: $e');
      _repertoireLines = [];
    }
  }

  /// Builds an opening tree from the current repertoire PGN.
  Future<void> _buildOpeningTree() async {
    if (_repertoirePgn == null || _repertoirePgn!.isEmpty) {
      _openingTree = OpeningTree();
      return;
    }

    try {
      String? repertoireColor;
      String? rootMoves;
      final lines = _repertoirePgn!.split('\n');

      for (final line in lines) {
        final trimmedLine = line.trim();
        if (trimmedLine.startsWith('// Color:')) {
          repertoireColor = trimmedLine.substring(9).trim();
        } else if (trimmedLine.startsWith('// Root:')) {
          rootMoves = trimmedLine.substring(8).trim();
        }
      }

      _rootMoves = rootMoves ?? '';

      _needsColorSelection = repertoireColor == null;
      final isWhiteRepertoire = repertoireColor != 'Black';
      _isRepertoireWhite = isWhiteRepertoire;

      final processedGames = <String>[];

      for (final chunk in pgn.splitPgnIntoGames(_repertoirePgn!)) {
        final headers = pgn.extractHeaders(chunk);
        final moveLines = <String>[];
        for (final line in chunk.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('[')) continue;
          moveLines.add(trimmed);
        }
        if (moveLines.isEmpty) continue;

        final game = _authoring.buildGame(
          event: headers['Event'],
          date: headers['Date'],
          white: headers['White'],
          black: headers['Black'],
          result: headers['Result'],
          moveLines: moveLines,
        );
        if (game != null) {
          processedGames.add(game);
        }
      }

      if (processedGames.isEmpty) {
        debugPrint('No games processed for tree building');
        _openingTree = OpeningTree();
        return;
      }

      _openingTree = await OpeningTreeBuilder.buildTree(
        pgnList: processedGames,
        username: '',
        userIsWhite: isWhiteRepertoire,
        maxDepth: kOpeningTreeMaxDepth,
        strictPlayerMatching: false,
      );

      debugPrint(
        'Built opening tree with ${_openingTree?.totalGames} total games',
      );
    } catch (e) {
      debugPrint('Failed to build opening tree: $e');
      _openingTree = OpeningTree();
    }
  }

  /// Imports PGN content into the current repertoire file.
  Future<int> importPgnContent(String pgnContent) async {
    if (_currentRepertoire == null) return 0;

    final filePath = _currentRepertoire!.filePath;
    final storage = StorageFactory.instance;
    if (!await storage.fileExists(filePath)) return 0;

    final gameCount = pgn.countPgnGames(pgnContent);

    final existing = await storage.readFile(filePath);
    if (existing == null) return 0;
    final separator = existing.endsWith('\n\n')
        ? ''
        : existing.endsWith('\n')
        ? '\n'
        : '\n\n';
    await storage.writeFile(filePath, '$existing$separator$pgnContent\n');

    await loadRepertoire();

    return gameCount > 0 ? gameCount : 1;
  }

  final List<Completer<void>> _loadCompleters = [];

  /// Returns a Future that completes when the current load finishes.
  /// Resolves immediately if no load is in progress.
  Future<void> awaitLoaded() {
    if (!_isLoading) return Future.value();
    final c = Completer<void>();
    _loadCompleters.add(c);
    return c.future;
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    if (!loading) {
      for (final c in _loadCompleters) {
        c.complete();
      }
      _loadCompleters.clear();
    }
    notifyListeners();
  }

  String _upsertMetadataComment(String content, String prefix, String value) {
    final lines = content.split('\n');
    final updated = <String>[];
    var inserted = false;

    for (final line in lines) {
      final trimmed = line.trim();

      if (trimmed.startsWith(prefix)) {
        if (!inserted) {
          updated.add('$prefix $value');
          inserted = true;
        }
        continue;
      }

      if (!inserted && trimmed.startsWith('[Event ')) {
        updated.add('$prefix $value');
        inserted = true;
      }

      updated.add(line);
    }

    if (!inserted) {
      updated.insert(0, '$prefix $value');
    }

    return updated.join('\n');
  }
}
