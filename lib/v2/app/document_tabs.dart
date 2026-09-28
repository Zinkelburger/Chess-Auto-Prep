import 'package:dartchess/dartchess.dart' show Side;

import '../chess/pgn/game_tree.dart';
import '../storage/chapter_files.dart';
import '../ui/pane_tabs.dart';
import '../workspace/document_history.dart';
import '../workspace/document_session.dart';
import 'workspace_requests.dart';
import 'mode.dart';

/// Open files and temporary analyses. The session remains the active document;
/// tabs retain navigation and drafts, while files are reread through its store.
final class DocumentTabs {
  DocumentTabs({required this.session, required this.requests}) {
    final page = _page();
    _pages[page.id] = page;
    tabs = PaneTabs([PaneTab(page.id, _title(page))]);
    session.anyChange.addListener(_follow);
    requests.addListener(_follow);
  }

  final DocumentSession session;
  final WorkspaceRequests requests;
  late final PaneTabs<Object> tabs;
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
      if (draft != null) session.restoreDraft(draft);
    } else if (page.board case final board?) {
      final result = await requests.analysisBoard(page: board);
      if (_disposed || result is! RequestDone) return;
    }
    requests.switchTo(mode);
    session.goTo(cursor);
    if (session.orientation != side) session.flip();
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
    tabs.remove(id);
    _pages.remove(id);
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
    draft = session.retainedDraft;
  }
}
