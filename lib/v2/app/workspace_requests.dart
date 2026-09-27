import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';

import '../chess/fen.dart';
import '../chess/pgn/analysis_board.dart' as boards;
import '../chess/pgn/game_tree.dart' show NodePath;
import '../chess/pgn/tree_edit.dart' show pathAlong;
import '../features/library/library.dart';
import '../features/library/library_messages.dart';
import '../features/library/library_state.dart';
import '../features/pgn_viewer/pgn_viewer.dart';
import '../features/study/study_commands.dart';
import '../storage/chapter_files.dart';
import '../workspace/books.dart';
import '../workspace/chapter_commands.dart';
import '../workspace/copy_name_dialog.dart';
import '../workspace/document_session.dart';
import '../chess/explorer_answer.dart' show ExplorerGame;
import '../chess/explorer_choice.dart' show ExplorerSource;
import '../workspace/game_fetcher.dart';
import '../workspace/session_results.dart';
import '../ui/error_bar.dart' show StatusAction;
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
    required Library library,
    required PgnViewer viewer,
    required GameFetcher games,
    required ExitGuard leaving,
    required WindowInput input,
    required Books books,
  }) : _books = books,
       _session = session,
       _library = library,
       _viewer = viewer,
       _games = games,
       _leaving = leaving,
       _input = input;

  final DocumentSession _session;
  final Books _books;
  final Library _library;
  final PgnViewer _viewer;
  final GameFetcher _games;

  /// Asked before another document takes the screen, so words the file
  /// never took are not carried off it without the user saying so.
  final ExitGuard _leaving;
  final WindowInput _input;

  var _mode = Mode.repertoires;
  String? _status;
  StatusAction? _statusAction;
  bool _disposed = false;

  /// Counts the requests that put something on the board or take it off,
  /// so one that waited can tell a later one was made meanwhile.
  int _asked = 0;

  Mode get mode => _mode;

  /// What the bar under the top bar says; null when it says nothing.
  String? get status => _status;

  /// The button beside [status], when it names a way out.
  StatusAction? get statusAction => _statusAction;

  /// Switching mode swaps the left column and nothing else: the same board,
  /// the same document and the same draft stay where they are. Back comes
  /// here again.
  void switchTo(Mode mode) {
    if (_disposed || mode == _mode) return;
    _remember();
    _mode = mode;
    notifyListeners();
  }

  /// The Books mode, at the active book: where every "Edit books" goes.
  void editBooks() {
    if (_books.active case final active?) _books.edit(active);
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

  Place get _here => Place(
    mode: _mode,
    source: _session.isScratch ? null : _session.source,
    game: _session.game,
    cursor: _session.cursor,
    scratch: _session.isScratch,
  );

  /// Keeps where the user is before a jump takes them elsewhere. Going
  /// somewhere new forgets the places Forward had.
  void _remember() {
    final here = _here;
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
    final place = from.removeLast();
    to.add(_here);
    _mode = place.mode;
    notifyListeners();
    if (place.scratch) {
      return _session.isScratch ? const RequestDone() : analysisBoard();
    }
    final source = place.source;
    if (source == null) return const RequestDone();
    final result = await _open(_nextRequest(), source, game: place.game);
    if (_disposed || result is! RequestDone) return result;
    _session.goTo(place.cursor);
    return result;
  }

  /// Puts [sentence] in the bar, with [action] beside it, or clears it:
  /// what a command came to when it did not do what was asked.
  void say(String? sentence, {StatusAction? action}) {
    if (_disposed || (sentence == _status && action == _statusAction)) return;
    _status = sentence;
    _statusAction = sentence == null ? null : action;
    notifyListeners();
  }

  /// Puts [ref] on the board, on [game] for a file read game by game.
  ///
  /// Clicking what is already open is not leaving it, so nothing is asked.
  /// When the user answered the draft question by saving a copy, the bar
  /// says where those words went.
  Future<RequestResult> open(ChapterRef ref, {int? game}) =>
      _open(_nextRequest(), ref, game: game);

  /// [open] for the request counted as [ticket], which may have waited for
  /// something else first.
  Future<RequestResult> _open(int ticket, ChapterRef ref, {int? game}) async {
    if (_overtaken(ticket)) return const RequestDropped();
    if (ref == _session.source && game == _session.game) {
      return const RequestDone();
    }
    final leave = await _leaving.mayLeaveDocument();
    if (_overtaken(ticket) || leave is! Go) return const RequestDropped();
    final result = await _session.open(ref, game: game);
    if (_overtaken(ticket)) return const RequestDropped();
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
  Future<RequestResult> openAt(ChapterRef ref, List<String> sans) async {
    final result = await open(ref);
    if (_disposed || result is! RequestDone) return result;
    if (_session.tree case final tree?) _session.goTo(pathAlong(tree, sans));
    return result;
  }

  /// [ref] in the Repertoire builder at the position [sans] reach: a file
  /// another mode found a move in.
  /// Back returns to where the user was, in the builder too.
  Future<RequestResult> readInBuilder(ChapterRef ref, List<String> sans) {
    if (_mode == Mode.repertoires) {
      _remember();
      notifyListeners();
    } else {
      switchTo(Mode.repertoires);
    }
    return openAt(ref, sans);
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
    _session.goTo(NodePath.of(List.filled(ply, 0)));
    if (_session.orientation != side) _session.flip();
    return result;
  }

  /// A file from the viewer's recent list: brought inside Documents if it
  /// is not, then opened in the viewer. When no copy could be made the
  /// viewer's list says why.
  Future<RequestResult> openFile(ChapterRef ref) async {
    final ticket = _nextRequest();
    final inside = await _viewer.fileFor(ref.path);
    if (_overtaken(ticket) || inside == null) return const RequestDropped();
    return _inViewer(ticket, inside);
  }

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
    if (_overtaken(ticket) || ref == null) return const RequestDropped();
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
    final kept = await _games.keep(game, source: source, ply: ply);
    if (_overtaken(ticket)) return const RequestDropped();
    switch (kept) {
      case GameNotKept(:final sentence):
        return _refused(sentence);
      case GameKept(:final ref, ply: final at):
        final result = await _inViewer(ticket, ref);
        if (_disposed || result is! RequestDone) return result;
        _session.goTo(NodePath.of(List.filled(at, 0)));
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
    final at = _session.fen;
    _session.showGame(index);
    if (_session.tree?.mainLineTo(at) case final path?) _session.goTo(path);
    return const RequestDone();
  }

  /// The desktop's file dialog, then the file as a new repertoire named
  /// after it, opened on its first chapter. No form: the name is changed
  /// from the list, and the side is asked when the chapter opens if the
  /// file did not say.
  Future<RequestResult> importFile() async {
    final ticket = _nextRequest();
    final result = await _library.importFile();
    if (_overtaken(ticket) || result == null) return const RequestDropped();
    return _imported(ticket, result, name: 'that file');
  }

  /// The clipboard as a new repertoire, the same way.
  Future<RequestResult> pasteRepertoire() async {
    final ticket = _nextRequest();
    final text = (await _input.clipboard())?.trim() ?? '';
    if (_overtaken(ticket)) return const RequestDropped();
    if (text.isEmpty) return _refused('Nothing to paste: copy a PGN first.');
    final result = await _library.importText(text, name: Library.pastedName);
    if (_overtaken(ticket)) return const RequestDropped();
    return _imported(ticket, result, name: Library.pastedName);
  }

  /// The analysis board as it was left, in place of the file that is up,
  /// with the same question about a draft the file never took as opening
  /// another one asks.
  Future<RequestResult> analysisBoard() async {
    final ticket = _nextRequest();
    if (_session.isScratch) return const RequestDone();
    final leave = await _leaving.mayLeaveDocument();
    if (_overtaken(ticket) || leave is! Go) return const RequestDropped();
    if (!await _session.showAnalysisBoard()) return const RequestDropped();
    _saidCopy(leave);
    return const RequestDone();
  }

  /// A new analysis board holding the line on the board up to where the
  /// user is, from whatever is up — a file, a game, the analysis board
  /// itself — and facing the same way, so it looks as it did.
  Future<RequestResult> newAnalysisBoard() async {
    final ticket = _nextRequest();
    final tree = _session.tree;
    final side = _session.orientation;
    final root = tree?.rootFen ?? Fen.initial;
    final sans = [
      if (tree != null)
        for (final node in tree.lineTo(_session.cursor)) node.san,
    ];
    final leave = await _leavingFile();
    if (_overtaken(ticket) || leave == null) return const RequestDropped();
    final shown = await _session.showAnalysisBoard(
      boards.analysisBoard(side: side, root: root, sans: sans),
    );
    if (!shown) return const RequestDropped();
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
    if (_overtaken(ticket) || leave == null) return const RequestDropped();
    final shown = await _session.showAnalysisBoard(
      boards.analysisBoard(side: side, root: root, sans: sans),
    );
    if (!shown || _overtaken(ticket)) return const RequestDropped();
    if (_session.tree case final tree?) {
      _session.goTo(pathAlong(tree, sans.take(ply).toList()));
    }
    _saidCopy(leave);
    return const RequestDone();
  }

  /// Ctrl+V: the clipboard onto the analysis board while it is up, else a
  /// new repertoire in the builder; anywhere else it does nothing.
  Future<RequestResult> paste() async {
    if (_session.isScratch) return pasteOntoBoard();
    if (_inLibrary) return pasteRepertoire();
    return const RequestDropped();
  }

  /// The clipboard — a PGN, bare moves or a FEN — as a new analysis board.
  Future<RequestResult> pasteOntoBoard() => _pasteAsBoard(boards.pastedBoard);

  /// Ctrl+Shift+V: a FEN on the clipboard as a new analysis board, from
  /// whatever is up.
  Future<RequestResult> pasteFen() => _pasteAsBoard(boards.pastedPosition);

  /// The clipboard read by [read] and, when it holds what [read] takes, put
  /// up as the analysis board — with the question about a file's draft
  /// asked only then, so a clipboard that holds nothing costs nothing.
  Future<RequestResult> _pasteAsBoard(
    boards.Pasted Function(String text, {required Side side}) read,
  ) async {
    final ticket = _nextRequest();
    final text = await _input.clipboard() ?? '';
    if (_overtaken(ticket)) return const RequestDropped();
    final boards.PastedBoard pasted;
    switch (read(text, side: _session.orientation)) {
      case boards.PasteRefused(:final reason):
        return _refused(reason);
      case final boards.PastedBoard board:
        pasted = board;
    }
    final leave = await _leavingFile();
    if (_overtaken(ticket) || leave == null) return const RequestDropped();
    if (!await _session.showAnalysisBoard(pasted.chapter)) {
      return const RequestDropped();
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
    if (_overtaken(ticket)) return const RequestDropped();
    if (result is LibraryAdded) {
      switchTo(Mode.repertoires);
      return _open(ticket, result.first);
    }
    final sentence = libraryMessage(
      result,
      thing: 'chapter',
      name: name,
      failed: 'Could not save the analysis board.',
    );
    return sentence == null ? const RequestDropped() : _refused(sentence);
  }

  /// The analysis board as a new chapter [name] at the end of [study], then
  /// that chapter open in Study.
  Future<RequestResult> saveBoardToStudy(ChapterRef study, String name) async {
    final board = _session.chapter;
    if (!_session.isScratch || board == null) return const RequestDropped();
    switchTo(Mode.study);
    final opened = await open(study, game: 0);
    if (_disposed || opened is! RequestDone) return opened;
    final refusal = addStudyChapter(
      _session,
      name: name,
      orientation: board.side,
      root: board.tree.rootFen,
      moves: board.tree,
    );
    return refusal == null ? const RequestDone() : _refused(refusal);
  }

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
    if (_overtaken(ticket) || leave is! Go) return const RequestDropped();
    _session.closed();
    _viewer.closed();
    _saidCopy(leave);
    return const RequestDone();
  }

  /// The viewer is the mode that shows files, so it comes to the front
  /// whichever mode asked, and the file is remembered once it is on the
  /// board.
  Future<RequestResult> _inViewer(int ticket, ChapterRef ref) async {
    switchTo(Mode.pgnViewer);
    final result = await _open(ticket, ref, game: 0);
    if (!_disposed && result is RequestDone) unawaited(_viewer.opened(ref));
    return result;
  }

  Future<RequestResult> _imported(
    int ticket,
    LibraryResult result, {
    required String name,
  }) {
    if (result is LibraryAdded) {
      if (!_inLibrary) switchTo(Mode.repertoires);
      return _open(ticket, result.first);
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
  void _saidCopy(Go leave) => say(switch (leave.copy) {
    final copy? => copySaid(CopySaved(copy)),
    null => null,
  });

  /// Supersedes navigation already in flight, including a read in the session.
  void cancelPending() {
    _asked++;
    _session.cancelOpening();
  }

  int _nextRequest() {
    cancelPending();
    return _asked;
  }

  /// Whether a newer intent or disposal overtook this request.
  bool _overtaken(int ticket) => _disposed || ticket != _asked;

  RequestRefused _refused(String sentence) {
    say(sentence);
    return RequestRefused(sentence);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
