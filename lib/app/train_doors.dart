import 'dart:async';

import '../features/trainer/trainer.dart';
import '../features/trainer/trainer_state.dart';
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

  Future<void> studyLesson() async {
    final trainer = this.trainer;
    final lesson = trainer.lesson;
    if (lesson == null || lesson.suspended) return;
    final line = lesson.line;
    final shown = lesson.drill.shown;
    trainer.suspend();
    final result = await requests.openLine(
      root: line.start,
      sans: line.moves.map((m) => m.san).toList(),
      ply: shown,
      side: line.side,
    );
    if (!mounted() || trainer.lesson != lesson) return;
    if (result is! RequestDone) {
      trainer.resume();
      return;
    }
    if (!view().layout.isOpen(WorkspaceTab.analysis))
      view().layout.reveal(WorkspaceTab.analysis);
    if (requests.mode == Mode.trainer) unawaited(workspace.analysis.enable());
  }
}
