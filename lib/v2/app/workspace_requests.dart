import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';

import '../chess/fen.dart';
import '../chess/pgn/analysis_board.dart' as boards;
import '../chess/pgn/game_tree.dart' show NodePath;
import '../chess/pgn/tree_edit.dart' show pathAlong;
import '../features/library/library.dart';
import '../features/library/library_messages.dart';
import '../features/pgn_viewer/pgn_viewer.dart';
import '../features/study/studies.dart';
import '../features/study/study_commands.dart';
import '../storage/chapter_files.dart';
import '../workspace/chapter_commands.dart';
import '../workspace/document_session.dart';
import '../chess/explorer_answer.dart' show ExplorerGame;
import '../chess/explorer_choice.dart' show ExplorerSource;
import '../workspace/fill_gaps.dart';
import '../workspace/game_fetcher.dart';
import '../workspace/session_results.dart';
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

/// The window's cross-mode requests: which mode fills the left column, the
/// one line the status bar says, and every way a document comes onto the
/// board or leaves it — a list's click, a file from the desktop, the
/// clipboard, a game the explorer lists.
///
/// Each document request goes through the same door, [open]: the draft of
/// the document being left is asked about first ([ExitGuard]), the session
/// opens the file, and what came of it is said. The requests do not queue
/// or refuse repeats; the session's own ticket makes the later of two opens
/// win, and an overtaken one drops without a word.
final class WorkspaceRequests extends ChangeNotifier {
  WorkspaceRequests({
    required DocumentSession session,
    required Library library,
    required Studies studies,
    required PgnViewer viewer,
    required GameFetcher games,
    required ExitGuard leaving,
    required WindowInput input,
  }) : _session = session,
       _library = library,
       _studies = studies,
       _viewer = viewer,
       _games = games,
       _leaving = leaving,
       _input = input;

  final DocumentSession _session;
  final Library _library;
  final Studies _studies;
  final PgnViewer _viewer;
  final GameFetcher _games;

  /// Asked before another document takes the screen, so words the file
  /// never took are not carried off it without the user saying so.
  final ExitGuard _leaving;
  final WindowInput _input;

  var _mode = Mode.repertoires;
  String? _status;
  bool _disposed = false;

  Mode get mode => _mode;

  /// What the bar under the top bar says; null when it says nothing.
  String? get status => _status;

  /// Switching mode swaps the left column and nothing else: the same board,
  /// the same document and the same draft stay where they are.
  void switchTo(Mode mode) {
    if (_disposed || mode == _mode) return;
    _mode = mode;
    notifyListeners();
    if (mode == Mode.study) unawaited(_studies.refresh());
  }

  /// Puts [sentence] in the bar, or clears it: what a command the window
  /// ran itself (a fill, a copy) came to.
  void say(String? sentence) {
    if (_disposed || sentence == _status) return;
    _status = sentence;
    notifyListeners();
  }

  /// Puts [ref] on the board, on [game] for a file read game by game.
  ///
  /// Clicking what is already open is not leaving it, so nothing is asked.
  /// When the user answered the draft question by saving a copy, the bar
  /// says where those words went.
  Future<RequestResult> open(ChapterRef ref, {int? game}) async {
    if (ref == _session.source && game == _session.game) {
      return const RequestDone();
    }
    final leave = await _leaving.mayLeaveDocument();
    if (_disposed || leave is! Go) return const RequestDropped();
    final result = await _session.open(ref, game: game);
    if (_disposed) return const RequestDropped();
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
  Future<RequestResult> readInBuilder(ChapterRef ref, List<String> sans) {
    switchTo(Mode.repertoires);
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
    final inside = await _viewer.fileFor(ref.path);
    if (_disposed || inside == null) return const RequestDropped();
    return _inViewer(inside);
  }

  /// Ctrl+O and `Open PGN file…` are one door whose other side depends on
  /// the mode: in the builder a file becomes a repertoire, everywhere else
  /// it is read in the viewer.
  Future<RequestResult> openPgnFile() =>
      _mode == Mode.repertoires ? importFile() : browse();

  /// The desktop's file dialog, then the same door as the recent list.
  Future<RequestResult> browse() async {
    final ref = await _viewer.browse();
    if (_disposed || ref == null) return const RequestDropped();
    return _inViewer(ref);
  }

  /// A game the explorer listed from [source]: kept as a file in the
  /// collections folder, then opened in the viewer at [ply], the ply the
  /// explorer was showing.
  Future<RequestResult> openExplorerGame(
    ExplorerGame game, {
    required ExplorerSource source,
    required int ply,
  }) async {
    final kept = await _games.keep(game, source: source, ply: ply);
    if (_disposed) return const RequestDropped();
    switch (kept) {
      case GameNotKept(:final sentence):
        return _refused(sentence);
      case GameKept(:final ref, ply: final at):
        final result = await _inViewer(ref);
        if (_disposed || result is! RequestDone) return result;
        _session.goTo(NodePath.of(List.filled(at, 0)));
        return result;
    }
  }

  /// The desktop's file dialog, then the file as a new repertoire named
  /// after it, opened on its first chapter. No form: the name is changed
  /// from the list, and the side is asked when the chapter opens if the
  /// file did not say.
  Future<RequestResult> importFile() async {
    final result = await _library.importFile();
    if (_disposed || result == null) return const RequestDropped();
    return _imported(result, name: 'that file');
  }

  /// The clipboard as a new repertoire, the same way.
  Future<RequestResult> pasteRepertoire() async {
    final text = (await _input.clipboard())?.trim() ?? '';
    if (_disposed) return const RequestDropped();
    if (text.isEmpty) return _refused('Nothing to paste: copy a PGN first.');
    final result = await _library.importText(text, name: Library.pastedName);
    if (_disposed) return const RequestDropped();
    return _imported(result, name: Library.pastedName);
  }

  /// The analysis board as it was left, in place of the file that is up,
  /// with the same question about a draft the file never took as opening
  /// another one asks.
  Future<RequestResult> analysisBoard() async {
    if (_session.isScratch) return const RequestDone();
    final leave = await _leaving.mayLeaveDocument();
    if (_disposed || leave is! Go) return const RequestDropped();
    await _session.showAnalysisBoard();
    _saidCopy(leave);
    return const RequestDone();
  }

  /// The item at [index] of what a search found, on the board: for a run
  /// on the analysis board, played onto it — the moves already there are
  /// followed, the rest added — and stopped where the item stops; for a run
  /// on a chapter, the draft it wrote opened there in the builder.
  Future<RequestResult> showFound(FillFound found, int index) async {
    final item = found.items[index];
    final moves = [for (final move in item.moves) move.move];
    switch (found.origin) {
      case InDraft(:final draft, :final sans):
        switchTo(Mode.repertoires);
        return openAt(draft, [
          ...sans,
          for (final move in moves.take(item.stopAfter)) move.san,
        ]);
      case OnTheBoard(:final root, :final line):
        final back = await analysisBoard();
        if (_disposed || back is! RequestDone) return back;
        if (_session.tree?.rootFen != root) {
          await _session.showAnalysisBoard(
            boards.analysisBoard(side: found.side, root: root),
          );
        }
        _session.goTo(const NodePath.root());
        for (final move in line) {
          _session.playMove(move.uci);
        }
        var stop = _session.cursor;
        for (final (i, move) in moves.indexed) {
          _session.playMove(move.uci);
          if (i + 1 == item.stopAfter) stop = _session.cursor;
        }
        _session.goTo(stop);
        return const RequestDone();
    }
  }

  /// A new analysis board holding the line on the board up to where the
  /// user is, from whatever is up — a file, a game, the analysis board
  /// itself — and facing the same way, so it looks as it did.
  Future<RequestResult> newAnalysisBoard() async {
    final tree = _session.tree;
    final side = _session.orientation;
    final root = tree?.rootFen ?? Fen.initial;
    final sans = [
      if (tree != null)
        for (final node in tree.lineTo(_session.cursor)) node.san,
    ];
    final leave = await _leavingFile();
    if (_disposed || leave == null) return const RequestDropped();
    await _session.showAnalysisBoard(
      boards.analysisBoard(side: side, root: root, sans: sans),
    );
    _saidCopy(leave);
    return const RequestDone();
  }

  /// Ctrl+V: the clipboard onto the analysis board while it is up, else a
  /// new repertoire in the builder; anywhere else it does nothing.
  Future<RequestResult> paste() async {
    if (_session.isScratch) return pasteOntoBoard();
    if (_mode == Mode.repertoires) return pasteRepertoire();
    return const RequestDropped();
  }

  /// The clipboard — a PGN, bare moves or a FEN — as a new analysis board.
  Future<RequestResult> pasteOntoBoard() async {
    final text = await _input.clipboard() ?? '';
    if (_disposed) return const RequestDropped();
    final leave = await _leavingFile();
    if (_disposed || leave == null) return const RequestDropped();
    switch (boards.pastedBoard(text, side: _session.orientation)) {
      case boards.PasteRefused(:final reason):
        return _refused(reason);
      case boards.PastedBoard(:final chapter):
        await _session.showAnalysisBoard(chapter);
    }
    if (_disposed) return const RequestDropped();
    _saidCopy(leave);
    return const RequestDone();
  }

  /// The analysis board as a new chapter [name] of [into], then that chapter
  /// open in the builder. The board stays as it was, to go back to.
  Future<RequestResult> saveBoardToRepertoire(
    RepertoireFolder into,
    String name,
  ) async {
    final board = _session.chapter;
    if (!_session.isScratch || board == null) return const RequestDropped();
    final result = await _library.saveBoard(into, name, board);
    if (_disposed) return const RequestDropped();
    if (result is LibraryAdded) {
      switchTo(Mode.repertoires);
      return open(result.first);
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
    if (_session.source == null) return const RequestDropped();
    final leave = await _leaving.mayLeaveDocument();
    if (_disposed || leave is! Go) return const RequestDropped();
    _session.closed();
    _viewer.closed();
    _saidCopy(leave);
    return const RequestDone();
  }

  /// The viewer is the mode that shows files, so it comes to the front
  /// whichever mode asked, and the file is remembered once it is on the
  /// board.
  Future<RequestResult> _inViewer(ChapterRef ref) async {
    switchTo(Mode.pgnViewer);
    final result = await open(ref, game: 0);
    if (!_disposed && result is RequestDone) unawaited(_viewer.opened(ref));
    return result;
  }

  Future<RequestResult> _imported(
    LibraryResult result, {
    required String name,
  }) {
    if (result is LibraryAdded) {
      switchTo(Mode.repertoires);
      return open(result.first);
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
    final copy? => 'Saved a copy as $copy',
    null => null,
  });

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
