import 'dart:async';

import '../features/trainer/trainer.dart';
import '../features/trainer/trainer_state.dart';
import '../workspace/latest.dart';
import '../workspace/workspace.dart';
import '../workspace/workspace_tabs.dart';
import 'mode.dart';
import 'mode_view.dart';
import 'workspace_requests.dart';

/// What the Train tab and the trainer's list send to the rest of the
/// window: a line to read, a course to import and train, and a lesson's
/// position to study on the Analysis tab.
final class TrainDoors {
  TrainDoors({
    required this.requests,
    required this.workspace,
    required this.trainer,
    required this.view,
    required this.mounted,
  });

  final WorkspaceRequests requests;
  final Workspace workspace;
  final Trainer trainer;

  /// The mode on screen now.
  final ModeView Function() view;

  /// Whether the window is still there to answer.
  final bool Function() mounted;

  /// A line the Train tab sent to be read: its chapter on the board at the
  /// position, in the builder when it asked for it, and the Moves tab up
  /// unless only the board was to move.
  Future<void> readLine(LineToRead line) async {
    final result = line.place == ReadIn.builder
        ? await requests.readInBuilder(line.ref, line.sans, game: line.game)
        : await requests.openAt(line.ref, line.sans, game: line.game);
    if (!mounted() || result is! RequestDone) return;
    if (line.place != ReadIn.board) view().show(WorkspaceTab.moves);
  }

  Future<void> importCourse() async {
    final result = await requests.importFile();
    if (!mounted() || result is! RequestDone) return;
    if (requests.mode == Mode.trainer) {
      final source = workspace.session.source;
      final selection = trainer.selection;
      final folder = selection.repertoires
          .where((r) => r.chapters.any((c) => c.path == source?.path))
          .firstOrNull;
      if (folder != null) selection.choose(folder);
    } else {
      trainer.setScope(TrainScope.chapter);
    }
    view().show(WorkspaceTab.train);
  }

  Ticket? _study;
  ({Record source, Ticket ticket, Future<RequestResult> ready})? _copy;

  bool get analyzing =>
      mounted() &&
      requests.mode == Mode.trainer &&
      view().layout.shows(WorkspaceTab.analysis);

  /// A board gesture or database row edits the document position. The
  /// explicit Analysis command copies the displayed Book continuation too.
  Future<void> analysisBoard([void Function()? edit]) async {
    if (trainer.board.value != null) {
      if (edit == null) await studyLesson();
      return;
    }
    if (_study?.current ?? false) return;
    final session = workspace.session;
    if (session.shownTo != null) return;
    if (!session.isScratch) {
      session.snapshot();
      final book = edit == null ? workspace.tree.board.value : null;
      Record source() => (
        session.chapter,
        session.cursor.value,
        session.cursor.navigation,
        session.cursor.commentLine.value,
        session.orientation,
        book == null || !workspace.tree.watching
            ? book
            : workspace.tree.board.value,
      );
      final from = source();
      final position = session.cursor.boardFen;
      var copy = _copy;
      if (copy == null || copy.ticket.overtaken || copy.source != from) {
        bool current() =>
            analyzing && trainer.board.value == null && source() == from;
        final line = book == null
            ? null
            : [for (final move in workspace.tree.offFile) move.uci];
        final ready = requests.newAnalysisBoard(
          continuation: line,
          current: current,
        );
        final ticket = requests.navigation;
        _study = null;
        _copy = copy = (source: from, ticket: ticket, ready: ready);
      }
      try {
        if (await copy.ready is! RequestDone ||
            copy.ticket.overtaken ||
            !session.isScratch ||
            session.cursor.boardFen != position) {
          return;
        }
      } finally {
        if (_copy == copy) _copy = null;
      }
    }
    if (analyzing && trainer.board.value == null) edit?.call();
  }

  /// Builder can keep the trainer's file without issuing a document request.
  void left() {
    if ((_study?.current ?? false) || (_copy?.ticket.current ?? false)) {
      requests.cancelPending(withdrawQuestion: true);
    }
    _study = null;
    _copy = null;
  }

  Future<void> studyLesson() async {
    final trainer = this.trainer;
    final lesson = trainer.lesson;
    if (lesson == null || trainer.board.value == null) return;
    final line = lesson.line;
    final shown = lesson.drill.shown;
    final page = requests.documents.tabs.selected;
    trainer.suspend();
    final opening = requests.openLine(
      root: line.start,
      sans: line.moves.map((m) => m.san).toList(),
      ply: shown,
      side: line.side,
      current: () => mounted() && trainer.lesson == lesson && lesson.suspended,
    );
    final ticket = _study = requests.navigation;
    final result = await opening;
    if (_study != ticket) return;
    _study = null;
    if (!mounted() || trainer.lesson != lesson || !lesson.suspended) return;
    if (result is! RequestDone || ticket.overtaken) {
      if (requests.documents.tabs.selected == page &&
          view().layout.shows(WorkspaceTab.train)) {
        trainer.resume();
      }
      return;
    }
    if (!view().layout.isOpen(WorkspaceTab.analysis)) {
      view().layout.reveal(WorkspaceTab.analysis);
    }
    if (requests.mode == Mode.trainer) unawaited(workspace.analysis.enable());
  }
}
