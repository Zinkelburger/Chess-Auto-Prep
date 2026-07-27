import 'package:chess_auto_prep/core/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screen-to-screen handoffs used to be nine loose mutable fields on
/// [AppState]. These tests pin the properties the sealed replacement buys:
/// a handoff is delivered to exactly one screen, exactly once, and related
/// values travel together instead of being cleared field by field.
void main() {
  group('routing', () {
    test('each handoff switches to the screen that can deliver it', () {
      final cases = <PendingHandoff, AppMode>{
        const OpenBuilder(repertoirePath: '/r.pgn'): AppMode.repertoire,
        const TrainRepertoire(sourcePath: '/r.pgn'): AppMode.repertoireTrainer,
        const TrainStudy(sourcePath: '/s.pgn'): AppMode.repertoireTrainer,
        const EditStudy(studyPath: '/s.pgn'): AppMode.study,
        const OpenPgnViewer(pgnPath: '/g.pgn'): AppMode.pgnViewer,
      };
      for (final entry in cases.entries) {
        final state = AppState();
        state.handOff(entry.key);
        expect(state.currentMode, entry.value, reason: '${entry.key}');
      }
    });

    test('parking a handoff notifies listeners once', () {
      final state = AppState();
      var notifications = 0;
      state.addListener(() => notifications++);
      state.handOff(const EditStudy(studyPath: '/s.pgn'));
      expect(notifications, 1);
    });
  });

  group('exactly-once delivery', () {
    test('takeHandoff returns the handoff and clears it', () {
      final state = AppState()..handOff(const EditStudy(studyPath: '/s.pgn'));
      expect(state.takeHandoff<EditStudy>()?.studyPath, '/s.pgn');
      expect(
        state.takeHandoff<EditStudy>(),
        isNull,
        reason: 'a second screen (or a later notification) must not re-fire it',
      );
    });

    test('takeHandoff of the wrong type leaves it for its real target', () {
      final state = AppState()..handOff(const OpenPgnViewer(pgnPath: '/g.pgn'));
      expect(state.takeHandoff<EditStudy>(), isNull);
      expect(
        state.takeHandoff<OpenPgnViewer>()?.pgnPath,
        '/g.pgn',
        reason: 'a mistaken read must not consume another screen’s work',
      );
    });

    test('hasPending peeks without consuming', () {
      final state = AppState()
        ..handOff(const OpenBuilder(repertoirePath: '/r.pgn'));
      expect(state.hasPending<OpenBuilder>(), isTrue);
      expect(state.hasPending<OpenBuilder>(), isTrue);
      expect(state.takeHandoff<OpenBuilder>(), isNotNull);
      expect(state.hasPending<OpenBuilder>(), isFalse);
    });

    test('takeHandoff on a fresh state is null, not a crash', () {
      expect(AppState().takeHandoff<OpenBuilder>(), isNull);
    });

    test('a newer handoff replaces one still waiting', () {
      final state = AppState()
        ..handOff(const OpenBuilder(repertoirePath: '/first.pgn'))
        ..handOff(const EditStudy(studyPath: '/s.pgn'));
      expect(
        state.takeHandoff<OpenBuilder>(),
        isNull,
        reason: 'the superseded route must not fire on a screen since left',
      );
      expect(state.takeHandoff<EditStudy>()?.studyPath, '/s.pgn');
    });
  });

  group('both trainer sources arrive through TrainerHandoff', () {
    test('a repertoire is not flagged as a study', () {
      final state = AppState()
        ..switchToTrainer(repertoirePath: '/r.pgn', lineId: 'L1');
      final handoff = state.takeHandoff<TrainerHandoff>()!;
      expect(handoff.sourcePath, '/r.pgn');
      expect(handoff.lineId, 'L1');
      expect(handoff.isStudy, isFalse);
    });

    test('a study is flagged as one', () {
      final state = AppState()
        ..switchToStudyTraining(path: '/s.pgn', lineId: 'C2');
      final handoff = state.takeHandoff<TrainerHandoff>()!;
      expect(handoff.sourcePath, '/s.pgn');
      expect(handoff.lineId, 'C2');
      expect(handoff.isStudy, isTrue);
    });
  });

  group('the named switchTo* helpers carry their whole payload', () {
    test('switchToBuilder carries the move sequence', () {
      final state = AppState()
        ..switchToBuilder(
          repertoirePath: '/r.pgn',
          lineId: 'L1',
          moveSequence: const ['e4', 'e5'],
        );
      final handoff = state.takeHandoff<OpenBuilder>()!;
      expect(handoff.repertoirePath, '/r.pgn');
      expect(handoff.lineId, 'L1');
      expect(handoff.moveSequence, ['e4', 'e5']);
      expect(handoff.generationPgnPaths, isNull);
    });

    test('switchToBuilderWithGeneration carries the PGN paths and no line', () {
      final state = AppState()
        ..switchToBuilderWithGeneration(
          repertoirePath: '/r.pgn',
          pgnPaths: const ['/a.pgn', '/b.pgn'],
        );
      final handoff = state.takeHandoff<OpenBuilder>()!;
      expect(handoff.generationPgnPaths, ['/a.pgn', '/b.pgn']);
      expect(
        handoff.lineId,
        isNull,
        reason: 'the old API had to null this field by hand',
      );
      expect(handoff.moveSequence, isNull);
    });

    test('switchToPgnViewer carries the optional slice FEN', () {
      final withSlice = AppState()
        ..switchToPgnViewer(path: '/g.pgn', sliceFen: 'fen-here');
      expect(withSlice.takeHandoff<OpenPgnViewer>()!.sliceFen, 'fen-here');

      final without = AppState()..switchToPgnViewer(path: '/g.pgn');
      expect(without.takeHandoff<OpenPgnViewer>()!.sliceFen, isNull);
    });
  });
}
