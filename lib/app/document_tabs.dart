import 'package:dartchess/dartchess.dart' show Side;

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
final class DocumentTabs {
  DocumentTabs({required this.session, required this.requests, this.drafts}) {
    final page = _page();
    _pages[page.id] = page;
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

  void _follow() {
    if (_disposed) return;
    final id = session.source ?? session.analysisPage;
    final known = _pages[id];
    final page = known ?? _page();
    page.remember(session);
    page.mode = requests.mode;
    _pages[id] = page;
    if (!tabs.isOpen(id) ||
        tabs.selected != id ||
        tabs.tabOf(id).title != _title(page)) {
      tabs.add(PaneTab(id, _title(page)));
    }
  }

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
    if (page.source case final source?) {
      final result = page.viewedFile
          ? await requests.openFile(source, game: page.game)
          : await requests.open(source, game: page.game);
      if (_disposed || result is! RequestDone || session.source != source)
        return;
      if (draft != null && !await _restore(page, source, draft)) return;
    } else if (page.board case final board?) {
      final result = await requests.analysisBoard(page: board);
      if (_disposed || result is! RequestDone) return;
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
      final open = tabs.open;
      if (open.length == 1) {
        if (await requests.newEmptyAnalysis() is! RequestDone) return;
      } else {
        final at = open.indexOf(id);
        await select(open[at == 0 ? 1 : at - 1]);
      }
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
