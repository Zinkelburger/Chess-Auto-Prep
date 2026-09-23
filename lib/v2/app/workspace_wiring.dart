import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../chess/generation/tree_wire_v4.dart' show treeWireVersion;
import '../diagnostics/log.dart';
import '../engines/engine_supervisor.dart';
import '../engines/fixed_depth.dart';
import '../features/library/library.dart';
import '../net/lichess_explorer.dart';
import '../storage/atomic_write.dart';
import '../storage/chapter_files.dart';
import '../storage/eval_cache.dart';
import '../storage/lichess_token.dart';
import '../storage/master_book.dart';
import '../workspace/engine_analysis.dart';
import '../workspace/explorer.dart';
import '../workspace/explorer_databases.dart';
import '../workspace/fill_gaps.dart';
import '../workspace/fill_sources.dart';
import '../workspace/game_fetcher.dart';
import '../workspace/gap_hunt.dart';
import '../workspace/replies.dart';
import '../workspace/repertoire_answers.dart';
import '../workspace/repertoire_shelf.dart';
import '../workspace/repertoire_tree.dart';
import '../workspace/reply_model.dart';
import '../workspace/workspace.dart';
import 'basics.dart';

/// Builds the [Workspace] over the [Basics] and keeps its owners in step
/// with the rest of the app: the engine follows the settings, and a change
/// to the repertoire files makes what was read from them be read again.
final class WorkspaceWiring {
  WorkspaceWiring(this._basics, this._library) {
    _library.addListener(_answers.forget);
    _library.addListener(_tree.forget);
    _fill.addListener(_listTheDraft);
  }

  final Basics _basics;
  final Library _library;

  late final workspace = Workspace(
    session: _basics.session,
    saver: _basics.saver,
    settings: _basics.settings,
    analysis: _analysis,
    explorer: _explorer,
    games: _games,
    replies: _replies,
    gaps: _gaps,
    shelf: _shelf,
    tree: _tree,
    fill: _fill,
  );

  late final _analysis = EngineAnalysis(
    _basics.session,
    _basics.launchEngine,
    multiPv: _basics.settings.value.engineLines,
    elsewhere: _tree.board,
  );

  /// The old app's master database, in the same support folder, read as it
  /// is: TWIC is listed when the file is there.
  late final _book = SqliteMasterBook(
    p.join(_basics.support.path, 'master_games.db'),
  );
  late final _databases = ExplorerDatabases(
    lichess: LichessExplorerApi(_basics.client, token: readLichessToken),
    book: _book,
  );
  late final _explorer = Explorer(
    session: _basics.session,
    settings: _basics.settings,
    databases: _databases,
  );
  late final _games = GameFetcher(
    databases: _databases,
    documents: _basics.store,
    collections: _basics.collections,
  );

  late final _answers = RepertoireAnswers(
    files: _basics.chapterFiles,
    documents: _basics.store,
  );
  late final _replyModel = ReplyModel(
    policy: _basics.maia,
    settings: _basics.settings,
  );
  late final _gaps = GapHunt(
    session: _basics.session,
    model: _replyModel,
    settings: _basics.settings,
    answers: _answers,
  );
  late final _replies = Replies(
    session: _basics.session,
    model: _replyModel,
    settings: _basics.settings,
    gaps: _gaps,
  );

  late final _shelf = RepertoireShelf(
    files: _basics.chapterFiles,
    documents: _basics.store,
  );
  late final _tree = RepertoireTree(session: _basics.session, shelf: _shelf);

  /// The engine's verdicts, shared with the old app, opened the first time
  /// a fill needs them.
  late final _evalCache = EvalCacheOnDemand(_basics.support);
  late final _fill = FillGaps(
    session: _basics.session,
    analysis: _analysis,
    documents: _basics.store,
    tools: _fillTools,
    keepTree: _keepTree,
  );

  /// A second Stockfish for the fill, with the pane's threads and table:
  /// the pane's own engine is paused for the run, so the machine is not
  /// shared, and quitting this one when the run ends costs nothing the pane
  /// has to rebuild.
  Future<FillToolsResult> _fillTools(FillRequest request) async {
    return switch (await _basics.launchEngine()) {
      StartFailed(:final reason) => FillUnavailable(reason),
      Started(:final engine) => FillReady(
        evaluator: CachedEvaluator(
          FixedDepthEvaluator(engine, depth: fillEvalDepth),
          _evalCache.cache,
          depth: fillEvalDepth,
        ),
        policy: MaiaOpponent(_basics.maia, elo: request.elo),
        release: engine.quit,
      ),
    };
  }

  /// The tree beside its chapter, where the old app keeps its own:
  /// `.cap-generation/<chapter>.pgn/<run>/tree.json`, create-only.
  Future<void> _keepTree(ChapterRef chapter, String tree) async {
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final folder = p.join(
      p.dirname(chapter.path),
      '.cap-generation',
      p.basename(chapter.path),
      'v2-$stamp',
    );
    await Directory(folder).create(recursive: true);
    await replaceFile(p.join(folder, 'tree.json'), utf8.encode(tree));
    log.i('kept the v$treeWireVersion tree of ${chapter.path} in $folder');
  }

  /// Starts the engine once the settings are read, and from then on has it
  /// follow them.
  Future<void> start() async {
    final s = _basics.settings.value;
    _engineRunsWith = (s.engineCores, s.engineMemoryMb);
    _analysis.setLines(s.engineLines);
    _basics.settings.addListener(_engineSettings);
    await _analysis.enable();
  }

  /// What the engine was last started with, so a settings change that
  /// touches neither its threads nor its table does not restart it.
  (int, int)? _engineRunsWith;

  /// More lines at once, or a new process for new threads or a new table.
  void _engineSettings() {
    final s = _basics.settings.value;
    _analysis.setLines(s.engineLines);
    final wanted = (s.engineCores, s.engineMemoryMb);
    if (_engineRunsWith != wanted) {
      _engineRunsWith = wanted;
      unawaited(_analysis.restart());
    }
  }

  /// A finished fill wrote a chapter the library has not listed; reading
  /// the folders again is what puts the draft in the outline. The fill
  /// notifies only when its own state changes, not with the document.
  void _listTheDraft() {
    if (_fill.state is FillDone) unawaited(_library.refresh());
  }

  void dispose() {
    _basics.settings.removeListener(_engineSettings);
    _library.removeListener(_answers.forget);
    _library.removeListener(_tree.forget);
    _fill.removeListener(_listTheDraft);
    _fill.dispose();
    _evalCache.close();
    _analysis.dispose();
    _replies.dispose();
    _gaps.dispose();
    _explorer.dispose();
    _tree.dispose();
    _games.dispose();
    _book.close();
  }
}
