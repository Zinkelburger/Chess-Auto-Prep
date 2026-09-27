import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import '../../support/generation_artifacts_fixture.dart';
import 'package:chess_auto_prep/app/training_dependencies.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_board_controller.dart';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/training/models/training_phase.dart';
import 'package:chess_auto_prep/features/training/controllers/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'training_fakes.dart';

/// The drill phase is exercised through its owner: it writes the controller's
/// session fields, and those are what the trainer widgets read.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late FakeRepertoireService repService;
  late FakeReviewService reviewService;
  late TrainingSessionController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('drill_phase_test');
    StorageFactory.instanceForTest = null;
    PathProviderPlatform.instance = FakePathProvider(tempDir.path);
    await File('${tempDir.path}/rep.pgn').writeAsString('1. e4 *');
    SharedPreferences.setMockInitialValues({});
    repService = FakeRepertoireService();
    reviewService = FakeReviewService();
    controller = createTrainingSession(
      artifacts: generationArtifactsFixture().repository,
      configuration: createTrainingSettings(),
      session: RepertoireBoardController(),
      repertoireService: repService,
      reviewService: reviewService,
    )..settings = fastSettings(wrongMoveReplay: false);
  });

  tearDown(() async {
    controller.dispose();
    StorageFactory.instanceForTest = null;
    await tempDir.delete(recursive: true);
  });

  Future<void> loadAndDrill() async {
    final path = p.join(tempDir.path, 'rep.pgn');
    repService.lines = [
      fakeLine('a', ['e4', 'e5', 'Nf3', 'Nc6']),
    ];
    // A stored rating makes the line "learned": it drills cold.
    reviewService.entries = [fakeEntry(path, 'a')];
    controller.setRepertoire(
      RepertoireMetadata(
        filePath: path,
        name: 'Rep',
        lastModified: DateTime.now(),
      ),
    );
    await controller.loadRepertoire();
    controller.startLine(controller.lines.single);
    await waitFor(() => controller.waitingForUser);
    expect(controller.phase, TrainingPhase.drilling);
    expect(controller.currentMoveIndex, 0);
  }

  test('a correct answer plays, pauses, then the reply and next prompt land '
      'together', () async {
    await loadAndDrill();
    await controller.handleUserMove(fakeMove(uci: 'e2e4', san: 'e4'));
    await waitFor(
      () => controller.waitingForUser && controller.currentMoveIndex == 2,
    );
    expect(controller.lineHadMistake, isFalse);
    expect(controller.currentPairOpponent?.san, 'e5');
    expect(controller.currentPairUser, isNull);
    expect(controller.session.fen, contains('4p3/4P3'));
  });

  test('a wrong answer is corrected on the board and remembered', () async {
    await loadAndDrill();
    final answered = controller.handleUserMove(
      fakeMove(uci: 'g1h3', san: 'Nh3'),
    );
    await waitFor(() => controller.feedback == 'Play e4');
    expect(controller.waitingForUser, isFalse, reason: 'input off meanwhile');
    await answered;
    await waitFor(
      () => controller.waitingForUser && controller.currentMoveIndex == 2,
    );
    expect(controller.lineHadMistake, isTrue);
    expect(controller.wrongMoveIndices, [0]);
    expect(controller.moveDifficulty(controller.currentLine!, 0), 0);
    expect(controller.session.fen, contains('4P3'), reason: 'e4 was played');
  });

  test('the line finishes after the last reply lands', () async {
    await loadAndDrill();
    await controller.handleUserMove(fakeMove(uci: 'e2e4', san: 'e4'));
    await waitFor(
      () => controller.waitingForUser && controller.currentMoveIndex == 2,
    );
    await controller.handleUserMove(fakeMove(uci: 'g1f3', san: 'Nf3'));
    await waitFor(() => controller.phase == TrainingPhase.finished);
    expect(controller.currentMoveIndex, 4);
    expect(controller.waitingForUser, isFalse);
    expect(controller.feedback, 'Line complete — rate your recall.');
  });
}
