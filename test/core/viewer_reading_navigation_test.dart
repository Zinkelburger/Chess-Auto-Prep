import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/features/documents/models/solitaire_script.dart';
import 'package:chess_auto_prep/features/documents/models/solitaire_reveal.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/documents/controllers/viewer_reading_controller.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_collection_controller.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_presentation_controller.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_analysis_port.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_opening_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_preferences_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_solitaire_repository.dart';
import '../support/fake_desktop_fullscreen_port.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_viewer_handle.dart';

class _RecordingHandle implements PgnViewerHandle {
  final calls = <String>[];

  @override
  int mainLineLength = 7;
  @override
  int get mainLineIndex => 0;
  @override
  bool get inVariation => false;
  @override
  void setSolitaireReveal(SolitaireReveal? reveal) {}
  @override
  void clearEphemeralMoves() => calls.add('clear');

  @override
  void addEphemeralMove(String san) => calls.add('move:$san');

  @override
  void goBack() => calls.add('back');

  @override
  void goForward() => calls.add('forward');

  @override
  void goToMainLineIndex(int moveIndex) => calls.add('index:$moveIndex');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// These commands perform no repository work. Unexpected calls fail the test.
class _Dependencies
    implements
        ViewerAnalysisPort,
        ViewerOpeningRepository,
        ViewerPreferencesRepository,
        ViewerSolitaireRepository {
  @override
  void cancel() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('$invocation');
}

void main() {
  test(
    'explicit reference navigation never drives the hidden game or tree',
    () {
      final game = _RecordingHandle();
      final book = _RecordingHandle();
      final dependencies = _Dependencies();
      final reading = ViewerReadingController(
        collection: ViewerCollectionController(),
        handle: game,
        analysis: dependencies,
        presentation: ViewerPresentationController(
          window: FakeDesktopFullscreenPort(),
          onChanged: () {},
        ),
        openings: dependencies,
        solitaireRepository: dependencies,
        preferences: dependencies,
        path: () => null,
        collectionLoading: () => false,
        index: () => null,
        onAnnotatedGame: (_, _) {},
        isActive: () => true,
      );
      addTearDown(reading.dispose);
      // A stale game-tree flag cannot redirect an explicitly selected reader.
      reading.tree.showOpeningTree = true;
      for (final command in <void Function()>[
        () => reading.onBoardMove('e4', reader: book),
        () => reading.navigateBack(reader: book),
        () => reading.navigateForward(reader: book),
        () => reading.navigateToStart(reader: book),
        () => reading.navigateToEnd(reader: book),
      ]) {
        reading.playback.start();
        command();
        expect(reading.playback.isPlaying, isFalse);
      }
      expect(book.calls, ['move:e4', 'back', 'forward', 'index:0', 'index:7']);
      expect(game.calls, isEmpty);

      // Fullscreen's explicit primary reader likewise ignores the tree flag.
      reading.navigateForward(reader: game);
      expect(game.calls, ['forward']);
      reading.tree.showOpeningTree = false;
      reading.navigateBack();
      reading.onBoardMove('d4');
      expect(game.calls, ['forward', 'back', 'move:d4']);
      expect(book.calls, hasLength(5));
      game.calls.clear();
      reading.tree.openingTree = OpeningTree()..appendLine(['e4', 'e5']);
      reading.tree.showOpeningTree = true;
      reading.navigateForward();
      expect(reading.tree.treeCurrentMoveSequence, ['e4']);
      reading.navigateToEnd();
      expect(reading.tree.treeCurrentMoveSequence, ['e4', 'e5']);
      reading.navigateBack();
      reading.navigateToStart();
      expect(reading.tree.treeCurrentMoveSequence, isEmpty);
      expect(game.calls, isEmpty);

      reading.tree.showOpeningTree = false;
      reading.solitaire.controller.start(
        script: const SolitaireScript(
          startMainlinePly: 0,
          includesVariations: false,
          steps: [
            SolitaireStep(san: 'e4', before: Chess.initial, mainlinePly: 0),
          ],
        ),
        userPlaysWhite: true,
      );
      game.calls.clear();
      reading.navigateToStart();
      reading.navigateToEnd();
      expect(game.calls, ['index:0', 'index:0']);
      expect(reading.solitaire.controller.waitingForUser, isTrue);
    },
  );
}
