import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;

import '../chess/fen.dart';
import '../chess/pgn/game_tree.dart';
import '../storage/chapter_files.dart';
import '../ui/pane_tabs.dart';
import '../workspace/document_history.dart';
import '../workspace/document_session.dart';
import '../workspace/draft_keeper.dart';
import 'workspace_requests.dart';
import 'mode.dart';

/// Open files and temporary analyses. The session remains the active document;
/// tabs retain navigation and drafts, while files are reread through its store.
///
/// Each tab belongs to one mode: the mode on screen when its document came
/// up, or the one a request handed it to ([carry]). Going to a mode brings
/// up its own most recent tab ([entered]); one with none gets the empty
/// analysis board. So no mode shows, or names, another mode's document.
final class DocumentTabs {
  DocumentTabs({required this.session, required this.requests, this.drafts})
    : _shown = session.source ?? session.analysisPage {
    final page = _page();
    _pages[page.id] = page;
    _recent.add(page.id);
    tabs = PaneTabs([PaneTab(page.id, _title(page))]);
    session.anyChange.addListener(_follow);
    requests.addListener(_follow);
  }

  final DocumentSession session;
  final WorkspaceRequests requests;
  late final PaneTabs<Object> tabs;

  /// The checkpoint of held viewer edits; a tab holding edits closes only
  /// once they are in it. Null where the viewer keeps no checkpoint.
  final DraftKeeper? drafts;
  final _pages = <Object, _DocumentPage>{};

  /// The tab of the document last seen on the board.
  Object _shown;

  /// Tabs in the order their documents were last up, the latest last.
  final _recent = <Object>[];

  /// The tab [select] is bringing back: it keeps its mode while its
  /// document comes up under the mode still on screen.
  Object? _selecting;
  bool _disposed = false;
  int _analysisCount = 1;

  _DocumentPage _page() => _DocumentPage(
    id: session.source ?? session.analysisPage,
    title:
        session.source?.name ??
        (_pages.isEmpty ? 'Analysis' : 'Analysis ${++_analysisCount}'),
    mode: requests.mode,
    source: session.source,
    viewedFile: requests.mode == Mode.pgnViewer && session.game != null,
    board: session.isScratch ? session.analysisPage : null,
  )..remember(session);

  String _title(_DocumentPage page) =>
      '${switch (page.mode) {
        Mode.repertoires => 'Builder',
        Mode.pgnViewer => 'Viewer',
        Mode.trainer => 'Trainer',
        final mode => mode.label,
      }} · ${page.title}';

  /// Follows the session and the mode. Only a document coming up changes
  /// which mode a tab belongs to: switching mode never retitles a tab.
  void _follow() {
    if (_disposed) return;
    final id = session.source ?? session.analysisPage;
    final page = _pages[id] ?? _page();
    page.remember(session);
    if (id != _shown) {
      if (id != _selecting) page.mode = requests.mode;
      _shown = id;
      _recent
        ..remove(id)
        ..add(id);
    }
    _pages[id] = page;
    _show(page);
  }

  void _show(_DocumentPage page) {
    final id = page.id;
    if (!tabs.isOpen(id) ||
        tabs.selected != id ||
        tabs.tabOf(id).title != _title(page)) {
      tabs.add(PaneTab(id, _title(page)));
    }
  }

  /// The document on the board now belongs to [mode]: a request put it up
  /// for that mode before the mode came on screen.
  void carry(Mode mode) {
    if (_disposed || !mode.showsBoard) return;
    final page = _pages[_shown];
    if (page == null || page.mode == mode) return;
    page.mode = mode;
    _show(page);
  }

  /// [mode] has come on screen because the user went there: unless the
  /// document up is already its own, its most recent tab comes back, or,
  /// with none, the empty analysis board. A mode with no board leaves the
  /// document alone.
  void entered(Mode mode) {
    if (_disposed || !mode.showsBoard) return;
    if (_pages[_shown]?.mode.sharesDocumentsWith(mode) ?? false) {
      carry(mode);
      return;
    }
    unawaited(_bringUp(mode));
  }

  /// [mode]'s latest tab other than [leaving]; else an empty board, the
  /// one up or one in a tab, taken into [mode]; else a new one.
  Future<void> _bringUp(Mode mode, {Object? leaving}) async {
    final own = _latest((page) => page.mode.sharesDocumentsWith(mode), leaving);
    if (own == null && _shown != leaving && _blankNow) {
      carry(mode);
      return;
    }
    final page = own ?? _latest((page) => page.isBlank, leaving ?? _shown);
    if (page == null) {
      await requests.newEmptyAnalysis();
      return;
    }
    page.mode = mode;
    await select(page.id);
  }

  _DocumentPage? _latest(bool Function(_DocumentPage) test, Object? leaving) {
    for (final id in _recent.reversed) {
      final page = _pages[id];
      if (id != leaving && page != null && tabs.isOpen(id) && test(page)) {
        return page;
      }
    }
    return null;
  }

  /// Whether the board up is an analysis board nothing was done on.
  bool get _blankNow =>
      session.isScratch &&
      !session.canUndo &&
      session.tree!.children.isEmpty &&
      session.tree!.rootFen == Fen.initial;

  Future<void> select(Object id) async {
    if (_disposed) return;
    if (tabs.selected == id) {
      requests.cancelPending();
      return;
    }
    final page = _pages[id];
    if (page == null) return;
    // Capture before the read notifies and updates the active page.
    final mode = page.mode;
    final cursor = page.cursor;
    final side = page.side;
    final draft = page.draft;
    _selecting = id;
    try {
      if (page.source case final source?) {
        final result = page.viewedFile
            ? await requests.openFile(source, game: page.game)
            : await requests.open(source, game: page.game);
        if (_disposed || result is! RequestDone || session.source != source) {
          return;
        }
        if (draft != null && !await _restore(page, source, draft)) return;
      } else if (page.board case final board?) {
        final result = await requests.analysisBoard(page: board);
        if (_disposed || result is! RequestDone) return;
      }
    } finally {
      if (_selecting == id) _selecting = null;
    }
    requests.switchTo(mode);
    session.goTo(cursor);
    if (session.orientation != side) session.flip();
  }

  /// Puts the edits [page] parked back on the file just read, and answers
  /// whether the tab may carry on. A draft of a file that changed since is
  /// not put back over it when its checkpoint holds it: the keeper offers it
  /// as a copy.
  Future<bool> _restore(
    _DocumentPage page,
    ChapterRef source,
    RetainedDraft draft,
  ) async {
    if (draft.revision != session.persistedRevision &&
        (await drafts?.keeps(source.path, draft) ?? false)) {
      page.draft = null;
      return !_disposed && session.source == source;
    }
    if (_disposed || session.source != source || session.hasHeldEdits) {
      return false;
    }
    session.restoreDraft(draft);
    return true;
  }

  Future<void> close(Object id) async {
    if (_disposed || !tabs.isOpen(id)) return;
    if (tabs.selected == id) {
      // The mode on screen stays: its next tab, or an empty board, comes up.
      await _bringUp(requests.mode, leaving: id);
      if (_disposed) return;
      if (tabs.selected == id) {
        requests.cancelPending();
        return;
      }
    }
    if (!await _letGo(id) ||
        _disposed ||
        !tabs.isOpen(id) ||
        tabs.selected == id) {
      return;
    }
    tabs.remove(id);
    _pages.remove(id);
    _recent.remove(id);
  }

  /// Whether the tab [id] may close: the edits it holds, if any, are in
  /// their checkpoint. When they cannot be written the tab stays open with
  /// them, and the bar says why.
  Future<bool> _letGo(Object id) async {
    final page = _pages[id];
    final path = page?.source?.path;
    final drafts = this.drafts;
    if (page?.draft == null || path == null || drafts == null) return true;
    final problem = await drafts.kept(path);
    if (problem == null) return true;
    if (!_disposed) requests.say('$problem Its tab stays open.');
    return false;
  }

  void dispose() {
    _disposed = true;
    session.anyChange.removeListener(_follow);
    requests.removeListener(_follow);
    tabs.dispose();
  }
}

final class _DocumentPage {
  _DocumentPage({
    required this.id,
    required this.title,
    required this.mode,
    this.source,
    this.board,
    required this.viewedFile,
  });
  final Object id;
  final String title;
  Mode mode;
  final ChapterRef? source;
  final bool viewedFile;
  final KeptBoard? board;
  int? game;
  NodePath cursor = const NodePath.root();
  Side side = Side.white;
  RetainedDraft? draft;

  /// Whether this is an analysis board, set aside, that nothing was done
  /// on: it is no mode's in particular.
  bool get isBlank {
    final kept = board;
    return kept != null &&
        !kept.canUndo &&
        kept.chapter.tree.children.isEmpty &&
        kept.chapter.tree.rootFen == Fen.initial;
  }

  void remember(DocumentSession session) {
    cursor = session.cursor;
    side = session.orientation;
    game = session.game;
    // Edits another reading of the file put away stay parked here; only
    // keeping or discarding them lets the tab forget them.
    final ended = session.heldEditsEnded;
    final retained = session.retainedDraft;
    if (retained != null ||
        ended == HeldEditsEnded.kept ||
        ended == HeldEditsEnded.discarded) {
      draft = retained;
    }
  }
}
