/// The breadcrumb label each handoff derives from its payload, plus the one
/// route `pending_handoff_test.dart` does not cover (Engine Tournament).
library;

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('defaultHistoryLabel', () {
    test('names the file without its directory or .pgn', () {
      expect(
        const OpenBuilder(
          repertoirePath: '/reps/Sicilian.pgn',
        ).defaultHistoryLabel,
        'Repertoire: Sicilian',
      );
      expect(
        const TrainRepertoire(
          sourcePath: '/reps/Sicilian.pgn',
        ).defaultHistoryLabel,
        'Training: Sicilian',
      );
      expect(
        const TrainStudy(
          sourcePath: '/studies/Tactics.pgn',
        ).defaultHistoryLabel,
        'Training: Tactics',
      );
      expect(
        const EditStudy(studyPath: '/studies/Tactics.pgn').defaultHistoryLabel,
        'Study: Tactics',
      );
      expect(
        const OpenPgnViewer(pgnPath: '/games/2026-08.pgn').defaultHistoryLabel,
        'PGN: 2026-08',
      );
    });

    test('handles Windows separators and an upper-case extension', () {
      expect(
        const OpenBuilder(
          repertoirePath: r'C:\reps\KID.PGN',
        ).defaultHistoryLabel,
        'Repertoire: KID',
      );
    });

    test('only strips a .pgn extension, and only the last one', () {
      expect(
        const OpenPgnViewer(pgnPath: '/g/my.games.pgn').defaultHistoryLabel,
        'PGN: my.games',
      );
      expect(
        const OpenPgnViewer(pgnPath: '/g/notes.txt').defaultHistoryLabel,
        'PGN: notes.txt',
      );
    });

    test('engine tournament is named after its id when it has one', () {
      expect(
        const OpenEngineTournament().defaultHistoryLabel,
        'Engine tournament',
      );
      expect(
        const OpenEngineTournament(
          tournamentId: 'sf-vs-maia',
        ).defaultHistoryLabel,
        'Tournament: sf-vs-maia',
      );
    });
  });

  group('OpenEngineTournament routing', () {
    test('switches to Engine Tournament and is delivered once', () {
      final state = AppState()
        ..handOff(const OpenEngineTournament(tournamentId: 't1'));
      expect(state.currentMode, AppMode.engineTournament);
      expect(state.takeHandoff<OpenEngineTournament>()?.tournamentId, 't1');
      expect(state.takeHandoff<OpenEngineTournament>(), isNull);
    });
  });
}
