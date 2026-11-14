import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';

import '../chess/explorer_answer.dart' show ExplorerGame;
import '../chess/explorer_choice.dart' show ExplorerSource;
import '../chess/fen.dart';
import '../chess/pgn/analysis_board.dart' as boards;
import '../chess/pgn/chapter.dart';
import '../chess/pgn/game_tree.dart' show NodePath;
import '../chess/pgn/study.dart' show ChapterDraft;
import '../chess/pgn/tree_edit.dart' show pathAlong;
import '../features/library/library.dart';
import '../features/library/library_messages.dart';
import '../features/library/library_state.dart';
import '../features/pgn_viewer/pgn_viewer.dart';
import '../features/study/studies.dart';
import '../features/study/studies_state.dart';
import '../storage/chapter_files.dart';
import '../storage/saved_place.dart';
import '../ui/status_bar.dart' show StatusAction;
import '../workspace/book/books.dart';
import '../workspace/document/chapter_commands.dart';
import '../workspace/document/document_actions.dart' show gameText;
import '../workspace/document/document_history.dart' show KeptBoard;
import '../workspace/document/document_session.dart';
import '../workspace/document/draft_keeper.dart';
import '../workspace/document/save_copy.dart';
import '../workspace/document/session_results.dart';
import '../workspace/explorer/game_fetcher.dart';
import '../workspace/latest.dart';
import 'document_tabs.dart';
import 'exit_guard.dart';
import 'mode.dart';
import 'window_input.dart';

/// What came of a request to put something on the board.
sealed class RequestResult {
  const RequestResult();
}

/// It is on the board, or it was already.
final class RequestDone extends RequestResult {
  const RequestDone();
}

/// It could not be done, and [sentence] — also in [WorkspaceRequests.status]
/// — says why.
final class RequestRefused extends RequestResult {
  const RequestRefused(this.sentence);

  final String sentence;
}

/// Nothing happened and nothing needs saying: the user stayed or closed a
/// dialog, a later request overtook this one, or the list that asked says
/// why itself.
final class RequestDropped extends RequestResult {
  const RequestDropped();
}

/// Where the user was, for Back and Forward: the mode, and the document on
/// the board and where in it.
final class Place {
  const Place({
    required this.mode,
    this.source,
    this.game,
    this.cursor = const NodePath.root(),
    this.scratch = false,
  });

  final Mode mode;

  /// The document on the board, or null for none or the analysis board.
  final ChapterRef? source;
  final int? game;
  final NodePath cursor;

  /// Whether the analysis board was up.
  final bool scratch;

  /// `My games`, `Repertoire builder · Najdorf`: what Back's tooltip names.
  String get label => switch (source) {
    final source? => '${mode.label} · ${source.name}',
    null => mode.label,
  };

  bool sameAs(Place other) =>
      other.mode == mode &&
      other.source == source &&
      other.game == game &&
      other.scratch == scratch;
}

/// The window's cross-mode requests: which mode fills the left column, the
/// one line the status bar says, and every way a document comes onto the
/// board or leaves it — a list's click, a file from the desktop, the
/// clipboard, a game the explorer lists.
///
/// Each document request goes through the same door, [open]: the draft of
/// the document being left is asked about first ([ExitGuard]), the session
/// opens the file, and what came of it is said. The requests do not queue
/// or refuse repeats: the latest one the user made wins. The session's own
/// ticket settles two reads; a request that waits before it reaches the
/// session — for a download, a copy into Documents, a file dialog, the
/// leave question — goes no further once a later one was made. An
/// overtaken request drops without a word.
final class WorkspaceRequests extends ChangeNotifier {
  WorkspaceRequests({
    required DocumentSession session,
    required this._library,
    required this._viewer,
    required this._games,
    required this._leaving,
    required this._input,
    required this._books,
    required this._studies,
    DraftKeeper? drafts,
  }) : _session = session {
    documents = DocumentTabs(session: session, requests: this, drafts: drafts);
  }

  late final DocumentTabs documents;

  final DocumentSession _session;
  final Books _books;
  final Studies _studies;
  final Library _library;
  final PgnViewer _viewer;
  final GameFetcher _games;

  /// Asked before another document takes the screen, so words the file
  /// never took are not carried off it without the user saying so.
  final ExitGuard _leaving;
  final WindowInput _input;

  /// The questions put to the user and the clipboard, for a mode that
  /// reads it on its own, as the Bughouse mode's paste does.
  WindowInput get input => _input;

  var _mode = Mode.repertoires;
  String? _status;
  StatusAction? _statusAction;
  bool _statusIsProblem = true;
  bool _disposed = false;

  /// The requests that put something on the board or take it off, so one
  /// that waited can tell a later one was made meanwhile.
  final _asked = Latest();

  Mode get mode => _mode;

  /// What the bar under the top bar says; null when it says nothing.
  String? get status => _status;

  /// The button beside [status], when it names a way out.
  StatusAction? get statusAction => _statusAction;

  /// Whether [status] says what could not be done, rather than where an
  /// outcome the user asked for went.
  bool get statusIsProblem => _statusIsProblem;

  /// The user goes to [mode]: its left column, and on the board the
  /// document it had up last, or an empty analysis board when it had none
  /// ([DocumentTabs.entered]). Another mode's document never comes along;
  /// a draft stays in its tab. Back comes here again, or to [from]: where
  /// the user was before a tab of [mode] put its document up.
  void switchTo(Mode mode, {Place? from}) {
    if (_disposed || mode == _mode) return;
    _showMode(mode, from: from);
    documents.entered(mode);
  }

  /// [mode] on screen for a document a request is about to put up in it,
  /// and how to put the window back — the mode it was asked from, Back and
  /// Forward as they were — when the document does not come after all.
  VoidCallback _showModeFor(Mode mode) {
    final left = _mode;
    if (_disposed || mode == left) return () {};
    final back = [..._back];
    final forward = [..._forward];
    _showMode(mode);
    return () {
      if (_disposed || _mode != mode) return;
      _back
        ..clear()
        ..addAll(back);
      _forward
        ..clear()
        ..addAll(forward);
      _mode = left;
      notifyListeners();
    };
  }

  /// [mode] on screen for a document a request is about to put up in it,
  /// so the mode's own is not brought back first.
  void _showMode(Mode mode, {Place? from}) {
    if (_disposed || mode == _mode) return;
    _remember(from ?? _here);
    _mode = mode;
    notifyListeners();
  }

  /// Where the window is, as the settings keep it for the next launch.
  SavedPlace get place {
    final source = _mode.showsBoard && !_session.isScratch
        ? _session.source
        : null;
    return SavedPlace(
      mode: _mode.name,
      path: source?.path,
      section: source?.section,
      game: source == null ? null : _session.game,
    );
  }

  /// Opens where the last run was left: its mode at once, so the window
  /// comes up on it, then its file. A file gone since leaves the mode on an
  /// empty board with nothing said, and Back has nowhere to go.
  Future<void> resume(SavedPlace? place) async {
    if (_disposed || place == null) return;
    final mode = Mode.values.where((m) => m.name == place.mode).firstOrNull;
    if (mode == null) return;
    if (mode != _mode) {
      _mode = mode;
      notifyListeners();
    }
    if (!mode.showsBoard) return;
    final path = place.path;
    if (path == null) return documents.entered(mode);
    final ticket = _nextRequest();
    final ref = ChapterRef.at(path, section: place.section);
    // The empty board the window was made with, which the file replaces.
    final blank = documents.tabs.selected;
    final result = mode == Mode.pgnViewer
        ? await _inViewer(ticket, ref)
        : await _open(ticket, ref, game: place.game);
    if (_disposed || ticket.overtaken) return;
    if (result is RequestDone) {
      documents.carry(mode);
      // Moves played on it while the file was read keep it open.
      return documents.closeIfBlank(blank);
    }
    if (result is RequestRefused) say(null);
    documents.entered(mode);
  }

  /// The Books mode, at the active book: where every "Edit books" goes.
  void editBooks() {
    if (_books.chosen case final chosen?) _books.edit(chosen);
    switchTo(Mode.books);
  }

  /// How many places Back and Forward keep.
  static const historyLimit = 30;

  final _back = <Place>[];
  final _forward = <Place>[];

  /// Where Back goes, or null when there is nowhere.
  Place? get backTo => _back.lastOrNull;

  /// Where Forward goes, or null when there is nowhere.
  Place? get forwardTo => _forward.lastOrNull;

  /// Where the user is now, for a jump that changes the mode only once its
  /// document is up ([switchTo]'s `from`).
  Place get here => _here;

  Place get _here => Place(
    mode: _mode,
    source: _session.isScratch ? null : _session.source,
    game: _session.game,
    cursor: _session.cursor.value,
    scratch: _session.isScratch,
  );

  /// Keeps where the user is before a jump takes them elsewhere. Going
  /// somewhere new forgets the places Forward had.
  void _remember(Place here) {
    if (_back.lastOrNull case final last? when last.sameAs(here)) {
      _back.removeLast();
    }
    _back.add(here);
    if (_back.length > historyLimit) _back.removeAt(0);
    _forward.clear();
  }

  /// Back to the place before the last jump: its mode, its document and
  /// where in it. A file gone since is left out and the mode alone comes.
  Future<RequestResult> back() => _travel(_back, _forward);

  /// Forward again, after Back.
  Future<RequestResult> forward() => _travel(_forward, _back);

  Future<RequestResult> _travel(List<Place> from, List<Place> to) async {
    if (_disposed || from.isEmpty) return const RequestDropped();
    final ticket = _nextRequest();
    final place = from.last;
    // The draft question comes before anything moves, so staying with an
    // unsaved draft leaves the window, its mode and both lists as they were.
    Go? leave;
    if (!_alreadyAt(place)) {
      // A note still in its editor is part of the draft asked about.
      _session.snapshot();
      final answer = await _leaving.mayLeaveDocument();
      if (ticket.overtaken ||
          answer is! Go ||
          !identical(from.lastOrNull, place)) {
        return const RequestDropped();
      }
      leave = answer;
    }
    final left = _mode;
    from.removeLast();
    to.add(_here);
    _mode = place.mode;
    notifyListeners();
    // Dropped and not overtaken, the document did not come after all — the
    // file will not take words typed since the question — and the window
    // and both lists are put back. A file gone since is refused, and the
    // mode alone comes.
    RequestResult stayed(RequestResult result) {
      if (result is! RequestDropped || ticket.overtaken) return result;
      to.removeLast();
      from.add(place);
      _mode = left;
      notifyListeners();
      return result;
    }

    if (place.scratch) {
      final result = _session.isScratch
          ? const RequestDone()
          : await _analysisBoard(ticket, left: leave);
      if (!_disposed && result is RequestDone) documents.carry(place.mode);
      return stayed(result);
    }
    final source = place.source;
    if (source == null) return const RequestDone();
    // The viewer is told its file again, as when it was read there first,
    // so its game list and reading place come back with it.
    final viewing = place.mode == Mode.pgnViewer;
    final saved = viewing ? await _viewer.savedPlace(source) : null;
    if (_disposed || ticket.overtaken) return const RequestDropped();
    final result = await _open(ticket, source, game: place.game, left: leave);
    if (_disposed || result is! RequestDone) return stayed(result);
    if (viewing && ticket.current && _viewer.file != source) {
      await _viewer.opened(
        source,
        place: saved,
        currentRequest: () => ticket.current,
      );
      if (_disposed || ticket.overtaken) return const RequestDropped();
      if (place.game case final game? when _session.game != game) {
        _session.showGame(game);
      }
    }
    documents.carry(place.mode);
    _session.cursor.goTo(place.cursor);
    return result;
  }

  /// Whether going to [place] leaves the document on the board where it is,
  /// so there is no draft to ask about.
  bool _alreadyAt(Place place) => switch (place) {
    Place(scratch: true) => _session.isScratch,
    Place(:final source?) =>
      source == _session.source && place.game == _session.game,
    _ => true,
  };

  /// Puts [sentence] in the bar, with [action] beside it, or clears it:
  /// what a command came to when it did not do what was asked, or, with
  /// [problem] false, where the result of one that worked went.
  void say(String? sentence, {StatusAction? action, bool problem = true}) {
    if (_disposed ||
        (sentence == _status &&
            action == _statusAction &&
            problem == _statusIsProblem)) {
      return;
    }
    _status = sentence;
    _statusAction = sentence == null ? null : action;
    _statusIsProblem = problem;
    notifyListeners();
  }

  /// Puts [ref] on the board, on [game] for a file read game by game.
  ///
  /// Clicking what is already open is not leaving it, so nothing is asked.
  /// When the user answered the draft question by saving a copy, the bar
  /// says where those words went.
  Future<RequestResult> open(ChapterRef ref, {int? game}) =>
      _open(_nextRequest(), ref, game: game);

  /// [ref] up in [mode], whichever mode asked. The draft question comes
  /// first, so staying leaves the window, its mode and Back as they were;
  /// then [mode] comes on screen, so the document comes up as its own; a
  /// document that does not come after all — refused, or overtaken by
  /// nothing the user asked for — puts the mode it was asked from back.
  Future<RequestResult> _openIn(
    Mode mode,
    Ticket ticket,
    ChapterRef ref, {
    int? game,
  }) async {
    if (ticket.overtaken) return const RequestDropped();
    Go? left;
    if (ref != _session.source || game != _session.game) {
      final answer = await _leaving.mayLeaveDocument();
      if (ticket.overtaken || answer is! Go) return const RequestDropped();
      left = answer;
    }
    final undo = _showModeFor(mode);
    final result = await _open(ticket, ref, game: game, left: left);
    if (!ticket.current) return result;
    if (result is RequestDone) {
      // A document already up was handed over: it is [mode]'s from now on.
      documents.carry(mode);
    } else {
      undo();
    }
    return result;
  }

  /// [open] for the request counted as [ticket], which may have waited for
  /// something else first.
  /// [left] is the answer to the draft question when the caller asked it.
  Future<RequestResult> _open(
    Ticket ticket,
    ChapterRef ref, {
    int? game,
    Go? left,
  }) async {
    if (ticket.overtaken) return const RequestDropped();
    if (ref == _session.source && game == _session.game) {
      return const RequestDone();
    }
    final leave = left ?? await _leaving.mayLeaveDocument();
    if (ticket.overtaken || leave is! Go) return const RequestDropped();
    final result = await _session.open(ref, game: game);
    if (ticket.overtaken) return const RequestDropped();
    switch (result) {
      case OpenOvertaken():
        return const RequestDropped();
      case DocumentOpened():
        _saidCopy(leave);
        unawaited(_askTheSide());
        return const RequestDone();
      case OpenFailed(:final reason):
        return _refused(reason);
    }
  }

  /// Puts [ref] on the board at the position [sans] reach from its start,
  /// or as far along them as the chapter still goes: a line the trainer
  /// sends to be read, which the file may have changed under since.
  Future<RequestResult> openAt(
    ChapterRef ref,
    List<String> sans, {
    int? game,
  }) async {
    final result = await open(ref, game: game);
    if (_disposed || result is! RequestDone) return result;
    if (_session.tree case final tree?) {
      _session.cursor.goTo(pathAlong(tree, sans));
    }
    return result;
  }

  /// [ref] in the Repertoire builder at the position [sans] reach: a file
  /// another mode found a move in.
  /// Back returns to where the user was, in the builder too.
  Future<RequestResult> readInBuilder(
    ChapterRef ref,
    List<String> sans, {
    int? game,
  }) async {
    final from = _here;
    final opening = openAt(ref, sans, game: game);
    final ticket = _asked.now;
    final result = await opening;
    if (ticket.overtaken) return const RequestDropped();
    if (result is! RequestDone) return result;
    // Commit navigation only after the document was accepted, but keep the
    // departure captured before the read so Back returns to the original file.
    _remember(from);
    documents.carry(Mode.repertoires);
    _mode = Mode.repertoires;
    notifyListeners();
    return result;
  }

  /// Game [game] of [ref] on the board, [ply] moves into it and seen from
  /// [side]: one of the user's own games, opened where something happened.
  Future<RequestResult> openGame(
    ChapterRef ref, {
    required int game,
    required int ply,
    required Side side,
  }) async {
    final result = await open(ref, game: game);
    if (_disposed || result is! RequestDone) return result;
    _session.cursor.goTo(NodePath.of(List.filled(ply, 0)));
    if (_session.orientation != side) _session.flip();
    return result;
  }

  /// A file from the viewer's recent list: brought inside Documents if it
  /// is not, then opened in the viewer. When no copy could be made the
  /// viewer's list says why. A named [game] is a handoff and leaves the
  /// saved reading place aside, unless [keepPlace]: a file's tab coming back
  /// keeps its order, filter rules and followed player.
  Future<RequestResult> openFile(
    ChapterRef ref, {
    int? game,
    bool keepPlace = false,
  }) async {
    final ticket = _nextRequest();
    final inside = await _viewer.fileFor(ref.path);
    if (ticket.overtaken || inside == null) return const RequestDropped();
    return _inViewer(ticket, inside, game: game, keepPlace: keepPlace);
  }

  /// A study's chapter read in the viewer, among the study's games. A study
  /// is the app's own file in Documents, so it opens where it is.
  Future<RequestResult> readInViewer(ChapterRef study, {int? game}) =>
      _inViewer(_nextRequest(), study, game: game);

  /// Ctrl+O and `Open PGN file…` are one door whose other side depends on
  /// the mode: in the builder a file becomes a repertoire, everywhere else
  /// it is read in the viewer.
  Future<RequestResult> openPgnFile() => _inLibrary ? importFile() : browse();

  /// The builder and the trainer both list the repertoires: a file opened
  /// or pasted in either becomes one, and stays in the mode that took it.
  bool get _inLibrary => _mode == Mode.repertoires || _mode == Mode.trainer;

  /// The desktop's file dialog, then the same door as the recent list.
  Future<RequestResult> browse() async {
    final ticket = _nextRequest();
    final ref = await _viewer.browse();
    if (ticket.overtaken || ref == null) return const RequestDropped();
    return _inViewer(ticket, ref);
  }

  /// A game the explorer listed from [source]: kept as a file in the
  /// collections folder, then opened in the viewer at [ply], the ply the
  /// explorer was showing.
  Future<RequestResult> openExplorerGame(
    ExplorerGame game, {
    required ExplorerSource source,
    required int ply,
  }) async {
    final ticket = _nextRequest();
    if (source == ExplorerSource.thisFile) return _showFileGame(game);
    // The position explored, not its move counters: a set-up position or a
    // game that got there by another move order is at another ply.
    final explored = _session.cursor.fen;
    final kept = await _games.keep(game, source: source, ply: ply);
    if (ticket.overtaken) return const RequestDropped();
    switch (kept) {
      case GameNotKept(:final sentence):
        return _refused(sentence);
      case GameKept(:final ref, ply: final at):
        final result = await _inViewer(ticket, ref, game: 0);
        if (_disposed || result is! RequestDone) return result;
        _session.cursor.goTo(
          _session.tree?.mainLineTo(explored) ??
              NodePath.of(List.filled(at, 0)),
        );
        return result;
    }
  }

  /// A game of the open file `This file` listed: already in hand, so it is
  /// put on the board without reading anything, at the position the
  /// explorer was showing, where its main line comes to it. A merged
  /// chapter has no other game to show, and the board stays where it is.
  RequestResult _showFileGame(ExplorerGame game) {
    final index = int.tryParse(game.id);
    if (index == null || _session.game == null) return const RequestDropped();
    final at = _session.cursor.fen;
    _session.showGame(index);
    if (_session.tree?.mainLineTo(at) case final path?) {
      _session.cursor.goTo(path);
    }
    return const RequestDone();
  }

  /// The desktop's file dialog, then the file as a new repertoire named
  /// after it, opened on its first chapter. No form: the name is changed
  /// from the list, and the side is asked when the chapter opens if the
  /// file did not say.
  Future<RequestResult> importFile() async {
    final ticket = _nextRequest();
    final result = await _library.importFile();
    if (ticket.overtaken || result == null) return const RequestDropped();
    return _imported(ticket, result, name: 'that file');
  }

  /// The clipboard as a new repertoire, the same way.
  Future<RequestResult> pasteRepertoire() async {
    final ticket = _nextRequest();
    final text = await _input.clipboard() ?? '';
    if (ticket.overtaken) return const RequestDropped();
    return _importPasted(ticket, text.trim());
  }

  Future<RequestResult> _importPasted(Ticket ticket, String text) async {
    if (text.isEmpty) return _refused('Nothing to paste: copy a PGN first.');
    final result = await _library.importText(text, name: Library.pastedName);
    if (ticket.overtaken) return const RequestDropped();
    return _imported(ticket, result, name: Library.pastedName);
  }

  /// The analysis board as it was left, in place of the file that is up,
  /// with the same question about a draft the file never took as opening
  /// another one asks.
  Future<RequestResult> analysisBoard({KeptBoard? page}) =>
      _analysisBoard(_nextRequest(), page: page);

  /// [analysisBoard] for the request counted as [ticket], with [left] the
  /// answer to the draft question when the caller asked it.
  Future<RequestResult> _analysisBoard(
    Ticket ticket, {
    KeptBoard? page,
    Go? left,
  }) async {
    if (_session.isScratch && page == null) return const RequestDone();
    final leave = left ?? await _leaving.mayLeaveDocument();
    if (ticket.overtaken || leave is! Go) return const RequestDropped();
    final shown = page == null
        ? await _session.showAnalysisBoard()
        : await _session.restoreAnalysisPage(page);
    if (!shown || ticket.overtaken) return const RequestDropped();
    _saidCopy(leave);
    return const RequestDone();
  }

  Future<RequestResult> newEmptyAnalysis() async {
    final ticket = _nextRequest();
    final leave = await _leavingFile();
    if (ticket.overtaken || leave == null) return const RequestDropped();
    if (!await _session.showAnalysisBoard(
          boards.analysisBoard(side: Side.white),
        ) ||
        ticket.overtaken) {
      return const RequestDropped();
    }
    _saidCopy(leave);
    return const RequestDone();
  }

  /// A separate analysis tab with the entire current game, its variations
  /// and comments, positioned and oriented exactly like the source.
  Future<RequestResult> newAnalysisBoard() async {
    if (_session.shownTo != null) return const RequestDropped();
    final ticket = _nextRequest();
    _session.snapshot();
    final cursor = _session.cursor.value;
    final preview = _session.cursor.commentLine.value;
    final side = _session.orientation;
    final board = withSide(
      await readChapter(
        name: boards.analysisBoardName,
        text: gameText(_session),
      ),
      side,
    );
    if (ticket.overtaken) return const RequestDropped();
    final leave = await _leavingFile();
    if (ticket.overtaken || leave == null) return const RequestDropped();
    final shown = await _session.showAnalysisBoard(board);
    if (!shown || ticket.overtaken) return const RequestDropped();
    _session.cursor.goTo(cursor);
    // A read-only line preview belongs only in the new scratch tab. Preserve
    // the full source game and insert the visible line as a variation there.
    if (preview != null) {
      for (final move in preview.moves.take(preview.at + 1)) {
        _session.playMove(move.uci);
      }
    }
    _saidCopy(leave);
    return const RequestDone();
  }

  /// A line on a new analysis board, from [root] seen from [side], with the
  /// board at the position [ply] moves in: a position the searches pointed
  /// out, with the moves to it and on past it to read, play over or save.
  Future<RequestResult> openLine({
    required Fen root,
    required List<String> sans,
    required int ply,
    required Side side,
  }) async {
    final ticket = _nextRequest();
    final leave = await _leavingFile();
    if (ticket.overtaken || leave == null) return const RequestDropped();
    final shown = await _session.showAnalysisBoard(
      boards.analysisBoard(side: side, root: root, sans: sans),
    );
    if (!shown || ticket.overtaken) return const RequestDropped();
    if (_session.tree case final tree?) {
      _session.cursor.goTo(pathAlong(tree, sans.take(ply).toList()));
    }
    _saidCopy(leave);
    return const RequestDone();
  }

  /// Ctrl+V: the clipboard, taken for what it holds. A FEN, a PGN or bare
  /// moves come up as a new analysis board, except that in the builder and
  /// the trainer, with a chapter up, a PGN becomes a new repertoire.
  Future<RequestResult> paste() => _paste(repertoire: true);

  /// Actions ▸ Paste FEN: a FEN on the clipboard, and nothing else, as a
  /// new analysis board.
  Future<RequestResult> pasteFen() => _paste(positionOnly: true);

  Future<RequestResult> _paste({
    bool positionOnly = false,
    bool repertoire = false,
  }) async {
    final ticket = _nextRequest();
    final text = await _input.clipboard() ?? '';
    if (ticket.overtaken) return const RequestDropped();
    if (_mode == Mode.bughouse) {
      return _refused(
        'Bughouse pastes from Actions: Paste FEN or dual FEN, or Paste moves.',
      );
    }
    if (repertoire &&
        _inLibrary &&
        !_session.isScratch &&
        text.trim().isNotEmpty &&
        boards.pastedFen(text) == null) {
      return _importPasted(ticket, text.trim());
    }
    return switch (positionOnly
        ? boards.pastedPosition(text)
        : boards.pastedBoard(text, side: _session.orientation)) {
      boards.PasteRefused(:final reason) => _refused(reason),
      boards.PastedBoard(:final chapter) => _toBoard(ticket, chapter),
    };
  }

  /// A position set up by hand as a new analysis board, seen from [side].
  Future<RequestResult> openPosition(Fen fen, {required Side side}) =>
      _toBoard(_nextRequest(), boards.analysisBoard(side: side, root: fen));

  /// The modes that show the analysis board where they are. The rest have
  /// no board, or one a lesson or a puzzle may hold, and send it to the
  /// builder.
  static const _keepBoard = {
    Mode.repertoires,
    Mode.pgnViewer,
    Mode.study,
    Mode.myGames,
    Mode.playerAnalysis,
  };

  /// [board] up as the analysis board, with the question about a file's
  /// draft asked only now, so a clipboard that holds nothing costs nothing.
  Future<RequestResult> _toBoard(Ticket ticket, Chapter board) async {
    final leave = await _leavingFile();
    if (ticket.overtaken || leave == null) return const RequestDropped();
    final from = _here;
    if (!await _session.showAnalysisBoard(board) || ticket.overtaken) {
      return const RequestDropped();
    }
    if (!_keepBoard.contains(_mode)) {
      _remember(from);
      documents.carry(Mode.repertoires);
      _mode = Mode.repertoires;
      notifyListeners();
    }
    _saidCopy(leave);
    return const RequestDone();
  }

  /// The analysis board as a new chapter [name] of [into], then that chapter
  /// open in the builder. The board stays as it was, to go back to.
  Future<RequestResult> saveBoardToRepertoire(
    RepertoireFolder into,
    String name,
  ) async {
    final ticket = _nextRequest();
    final board = _session.chapter;
    if (!_session.isScratch || board == null) return const RequestDropped();
    final result = await _library.saveBoard(into, name, board);
    if (ticket.overtaken) return const RequestDropped();
    if (result is LibraryAdded) {
      return _openIn(Mode.repertoires, ticket, result.first);
    }
    final sentence = libraryMessage(
      result,
      thing: 'chapter',
      name: name,
      failed: 'Could not save the analysis board.',
    );
    return sentence == null ? const RequestDropped() : _refused(sentence);
  }

  /// The analysis board as the first chapter of a new repertoire [name],
  /// opened in the builder.
  Future<RequestResult> saveBoardAsRepertoire(String name) async {
    final ticket = _nextRequest();
    final board = _session.chapter;
    if (!_session.isScratch || board == null) return const RequestDropped();
    final result = await _library.saveBoardAsRepertoire(name, board);
    if (ticket.overtaken) return const RequestDropped();
    if (result is LibraryAdded) {
      return _openIn(Mode.repertoires, ticket, result.first);
    }
    final sentence = libraryMessage(
      result,
      thing: 'repertoire',
      name: name,
      failed: 'Could not save the analysis board.',
    );
    return sentence == null ? const RequestDropped() : _refused(sentence);
  }

  /// [drafts] into a study the user picks — one of theirs, or a new one —
  /// from whatever mode they are in, which stays up: the bar says where
  /// they went, with `Open study` to go there.
  Future<RequestResult> addToStudy(List<ChapterDraft> drafts) async {
    if (drafts.isEmpty || _disposed) return const RequestDropped();
    await _studies.refresh();
    if (_disposed) return const RequestDropped();
    final pick = await _input.studyFor(
      studies: _studies.studies,
      chapter: drafts.length == 1 ? drafts.single.name : null,
      count: drafts.length,
    );
    if (_disposed || pick == null) return const RequestDropped();
    final named = drafts.length == 1
        ? [drafts.single.named(pick.name)]
        : drafts;
    return _added(await _studies.addChapters(pick.into, named), named.length);
  }

  RequestResult _added(StudyResult result, int count) {
    if (_disposed) return const RequestDropped();
    switch (result) {
      case StudyDone(opened: final study?, :final chapter):
        say(
          count == 1
              ? 'Added a chapter to ${study.name}.'
              : 'Added $count chapters to ${study.name}.',
          action: (
            label: 'Open study',
            onPressed: () => unawaited(openStudy(study, chapter: chapter ?? 0)),
          ),
          problem: false,
        );
        return const RequestDone();
      case StudyDone():
        return const RequestDropped();
      case StudyProblem(:final sentence):
        return _refused(sentence);
    }
  }

  /// [study] in Study, on [chapter].
  Future<RequestResult> openStudy(ChapterRef study, {int chapter = 0}) =>
      _openIn(Mode.study, _nextRequest(), study, game: chapter);

  /// The answer to the draft question when a file is up, or [Go] at once
  /// when the analysis board is: it has no file to ask about. Null when the
  /// user stayed.
  Future<Go?> _leavingFile() async {
    if (_session.isScratch) return const Go();
    final leave = await _leaving.mayLeaveDocument();
    return leave is Go ? leave : null;
  }

  /// Takes the document off the board, with the same question about a
  /// draft the file never took as opening another one asks.
  Future<RequestResult> closeFile() async {
    final ticket = _nextRequest();
    if (_session.source == null) return const RequestDropped();
    final leave = await _leaving.mayLeaveDocument();
    if (ticket.overtaken || leave is! Go) return const RequestDropped();
    _session.closed();
    _viewer.closed();
    _saidCopy(leave);
    return const RequestDone();
  }

  /// The viewer is the mode that shows files, so it comes to the front
  /// whichever mode asked, and the file is remembered once it is on the
  /// board.
  Future<RequestResult> _inViewer(
    Ticket ticket,
    ChapterRef ref, {
    int? game,
    bool keepPlace = false,
  }) async {
    final place = game == null || keepPlace
        ? await _viewer.savedPlace(ref)
        : null;
    if (ticket.overtaken) return const RequestDropped();
    final result = await _openIn(Mode.pgnViewer, ticket, ref, game: game ?? 0);
    if (ticket.current && result is RequestDone) {
      await _viewer.opened(
        ref,
        place: place,
        currentRequest: () => ticket.current,
      );
    }
    return ticket.overtaken ? const RequestDropped() : result;
  }

  Future<RequestResult> _imported(
    Ticket ticket,
    LibraryResult result, {
    required String name,
  }) {
    if (result is LibraryAdded) {
      return _inLibrary
          ? _open(ticket, result.first)
          : _openIn(Mode.repertoires, ticket, result.first);
    }
    final sentence = libraryMessage(
      result,
      thing: 'repertoire',
      name: name,
      failed: 'Could not import the repertoire.',
    );
    if (sentence != null) return Future.value(_refused(sentence));
    say(null);
    return Future.value(const RequestDropped());
  }

  /// A repertoire chapter whose file does not say which side it is for is
  /// asked about once, and the answer is written into the file, so the
  /// question never comes back. Dismissing it leaves the file as it was,
  /// read as White, and it is asked again the next time the chapter opens.
  Future<void> _askTheSide() async {
    final chapter = _session.chapter;
    if (chapter == null || chapter.game != null || chapter.sideStated) return;
    final source = _session.source;
    final side = await _input.sideFor(chapter.name);
    if (_disposed || side == null || _session.source != source) return;
    setSide(_session, side);
  }

  /// The bar after a document came or went: where a copy the leave question
  /// wrote went, or nothing.
  void _saidCopy(Go leave) => switch (leave.copy) {
    final copy? => sayCopy(say, CopySaved(copy)),
    null => say(null),
  };

  /// Supersedes navigation already in flight, including a read in the session.
  void cancelPending() {
    _asked.cancel();
    _session.cancelOpening();
  }

  Ticket _nextRequest() {
    cancelPending();
    return _asked.now;
  }

  RequestRefused _refused(String sentence) {
    say(sentence);
    return RequestRefused(sentence);
  }

  @override
  void dispose() {
    _disposed = true;
    _asked.close();
    documents.dispose();
    super.dispose();
  }
}
