import 'dart:io';

import 'package:chess_auto_prep/models/completed_move.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/models/repertoire_move_progress.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/models/repertoire_review_history_entry.dart';
import 'package:chess_auto_prep/models/training_settings.dart';
import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:chess_auto_prep/services/training/training_phase.dart';
import 'package:chess_auto_prep/services/training/training_session_controller.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Routes path_provider's documents directory to a per-test temp dir so any
/// storage fallback (e.g. the tree.json playability probe) touches real files
/// in an isolated location instead of the user's data.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// In-memory [RepertoireService]: parse returns canned lines, header writes
/// are recorded instead of touching disk.
class _FakeRepertoireService extends RepertoireService {
  List<RepertoireLine> lines = [];
  Object? parseError;
  final headerUpdates = <String>[];

  @override
  Future<List<RepertoireLine>> parseRepertoireFile(
    String filePath, {
    String? trainingColor,
    bool colorFromStartingSide = false,
  }) async {
    if (parseError != null) throw parseError!;
    return List.of(lines);
  }

  @override
  Future<bool> updateLineReviewHeaders(
    String filePath,
    String lineId, {
    required DateTime? lastReview,
    required double difficulty,
    required double intervalDays,
    required DateTime? dueDate,
    required int passCount,
    required int failCount,
  }) async {
    headerUpdates.add(lineId);
    return true;
  }
}

/// In-memory [RepertoireReviewService]: the pure scheduling logic
/// (syncEntries, orderLinesForReview, applyRating) stays real; only the CSV
/// persistence is replaced.
class _FakeReviewService extends RepertoireReviewService {
  List<RepertoireReviewEntry> entries = [];
  List<RepertoireMoveProgress> progress = [];
  final history = <RepertoireReviewHistoryEntry>[];
  int saveAllCalls = 0;
  Duration loadDelay = Duration.zero;

  @override
  Future<List<RepertoireReviewEntry>> loadAll() async {
    if (loadDelay > Duration.zero) await Future<void>.delayed(loadDelay);
    return List.of(entries);
  }

  @override
  Future<void> saveAll(List<RepertoireReviewEntry> entries) async {
    saveAllCalls++;
    this.entries = List.of(entries);
  }

  @override
  Future<List<RepertoireMoveProgress>> loadMoveProgress() async =>
      List.of(progress);

  @override
  Future<void> saveMoveProgress(
    List<RepertoireMoveProgress> entries, {
    String? repertoireId,
  }) async {
    progress = List.of(entries);
  }

  @override
  Future<void> appendHistory(List<RepertoireReviewHistoryEntry> entries) async {
    history.addAll(entries);
  }
}

RepertoireLine _line(
  String id,
  List<String> moves, {
  double? importance,
  Map<String, String> comments = const {},
}) {
  return RepertoireLine(
    id: id,
    name: 'Line $id',
    moves: moves,
    color: 'white',
    startPosition: Chess.initial,
    fullPgn: '',
    comments: comments,
    importance: importance,
  );
}

RepertoireReviewEntry _entry(
  String repertoireId,
  String lineId, {
  String lastRating = 'good',
  DateTime? due,
  String lineName = '',
}) {
  return RepertoireReviewEntry(
    repertoireId: repertoireId,
    lineId: lineId,
    lineName: lineName.isEmpty ? lineId : lineName,
    lastRating: lastRating,
    dueDateUtc: due,
  );
}

CompletedMove _move({String uci = '', String san = ''}) => CompletedMove(
  from: '',
  to: '',
  san: san,
  fenBefore: '',
  fenAfter: '',
  uci: uci,
);

/// 1 ms pacing everywhere so drill chains settle fast; learn stops at the
/// acknowledge gate instead of running timers.
TrainingSettings _fastSettings({
  bool wrongMoveReplay = true,
  bool autoNext = false,
  ReviewOrder reviewOrder = ReviewOrder.sequential,
  int correctStreakThreshold = 3,
}) {
  return TrainingSettings(
    moveSpeedMs: 1,
    introSpeedMs: 1,
    skipToFirstComment: false,
    learnRequiresClick: true,
    wrongMoveReplay: wrongMoveReplay,
    autoNext: autoNext,
    reviewOrder: reviewOrder,
    correctStreakThreshold: correctStreakThreshold,
  );
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > timeout) {
      fail('Timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakeRepertoireService repService;
  late _FakeReviewService reviewService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('training_session_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SharedPreferences.setMockInitialValues({});
    repService = _FakeRepertoireService();
    reviewService = _FakeReviewService();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  TrainingSessionController buildController() {
    return TrainingSessionController(
      repertoireService: repService,
      reviewService: reviewService,
    )..settings = _fastSettings();
  }

  String repPath() => '${tempDir.path}/rep.pgn';

  RepertoireMetadata meta() => RepertoireMetadata(
    filePath: repPath(),
    name: 'Rep',
    lastModified: DateTime.now(),
  );

  group('loadRepertoire', () {
    test(
      'happy path: lines parsed, entries synced, due queue ordered',
      () async {
        repService.lines = [
          _line('A', ['e4', 'e5'], importance: 0.2),
          _line('B', ['d4', 'd5'], importance: 0.9),
          _line('C', ['c4']),
        ];
        // A was reviewed and is not due until tomorrow; B and C are new.
        reviewService.entries = [
          _entry('other.pgn', 'X'),
          _entry(
            repPath(),
            'A',
            due: DateTime.now().toUtc().add(const Duration(days: 1)),
            lineName: 'stale name',
          ),
        ];
        reviewService.progress = [
          RepertoireMoveProgress(
            repertoireId: repPath(),
            lineId: 'A',
            moveIndex: 0,
            correctStreak: 2,
            learned: false,
          ),
          RepertoireMoveProgress(
            repertoireId: 'other.pgn',
            lineId: 'X',
            moveIndex: 0,
            correctStreak: 1,
            learned: false,
          ),
        ];

        final controller = buildController()
          ..settings = _fastSettings(reviewOrder: ReviewOrder.byImportance)
          ..setRepertoire(meta());
        await controller.loadRepertoire();

        expect(controller.isLoading, isFalse);
        expect(controller.error, isNull);
        expect(controller.lines, hasLength(3));

        // Every line has a synced review entry; existing names refresh.
        expect(controller.reviewMap.keys, containsAll(['A', 'B', 'C']));
        expect(controller.reviewMap['A']!.lineName, 'Line A');

        // Merged entries were saved back without dropping other repertoires.
        expect(reviewService.saveAllCalls, 1);
        expect(reviewService.entries, hasLength(4));
        expect(
          reviewService.entries.map((e) => e.repertoireId),
          contains('other.pgn'),
        );

        // Only this repertoire's move progress is indexed.
        expect(controller.moveProgressMap.keys, ['A:0']);

        // A is not due, so the queue is B then C (importance desc, null last).
        expect(controller.dueQueue.map((l) => l.id), ['B', 'C']);

        // Loading lands on the line browser; nothing auto-starts.
        expect(controller.currentLine, isNull);

        // Starting the queue picks the first due line; B is new, so it opens
        // in learning.
        controller.pickStartingLine();
        expect(controller.currentLine!.id, 'B');
        expect(controller.phase, TrainingPhase.learning);
        expect(controller.hadLearnPhaseThisSession, isTrue);

        // The learn walkthrough halts at the acknowledge gate.
        await _waitFor(() => controller.learnWaitingForAck);
        controller.dispose();
      },
    );

    test('empty file sets error and clears loading', () async {
      repService.lines = [];
      final controller = buildController()..setRepertoire(meta());

      await controller.loadRepertoire();

      expect(controller.error, 'No trainable lines found.');
      expect(controller.isLoading, isFalse);
      expect(controller.dueQueue, isEmpty);
      expect(controller.currentLine, isNull);
      controller.dispose();
    });

    test('parse failure surfaces the error and clears loading', () async {
      repService.parseError = Exception('boom');
      final controller = buildController()..setRepertoire(meta());

      await controller.loadRepertoire();

      expect(controller.error, contains('Error loading repertoire'));
      expect(controller.error, contains('boom'));
      expect(controller.isLoading, isFalse);
      controller.dispose();
    });

    test('no repertoire set is a no-op', () async {
      final controller = buildController();
      await controller.loadRepertoire();
      expect(controller.isLoading, isTrue, reason: 'untouched initial state');
      controller.dispose();
    });
  });

  test('setIdle clears loading and error, and notifies', () {
    final controller = buildController();
    var notified = 0;
    controller.addListener(() => notified++);
    controller.error = 'stale';

    controller.setIdle();

    expect(controller.isLoading, isFalse);
    expect(controller.error, isNull);
    expect(notified, 1);
    controller.dispose();
  });

  group('isCorrectUserMove', () {
    test('matches by UCI against the expected SAN', () {
      final controller = buildController();
      expect(
        controller.isCorrectUserMove(_move(uci: 'e2e4', san: 'e4'), 'e4'),
        isTrue,
      );
      controller.dispose();
    });

    test('a different legal move is rejected even with a legal UCI', () {
      final controller = buildController();
      expect(
        controller.isCorrectUserMove(_move(uci: 'd2d4', san: 'd4'), 'e4'),
        isFalse,
      );
      controller.dispose();
    });

    test('falls back to normalized SAN when the UCI cannot be played', () {
      final controller = buildController();
      // e2e5 is illegal from the start position, so the FEN comparison
      // throws and the SAN fallback decides: suffixes and case are ignored.
      expect(
        controller.isCorrectUserMove(_move(uci: 'e2e5', san: 'e4!?'), 'e4'),
        isTrue,
      );
      expect(
        controller.isCorrectUserMove(_move(uci: 'e2e5', san: 'E4+'), 'e4'),
        isTrue,
      );
      expect(
        controller.isCorrectUserMove(_move(uci: 'e2e5', san: 'd4'), 'e4'),
        isFalse,
      );
      controller.dispose();
    });

    test('unparsable expected SAN never matches', () {
      final controller = buildController();
      expect(
        controller.isCorrectUserMove(_move(uci: 'e2e4', san: 'Zz9'), 'Zz9'),
        isFalse,
      );
      controller.dispose();
    });
  });

  group('drill phase transitions', () {
    test('correct move advances, wrong move records mistake, replay runs, '
        'rating counts the mistake', () async {
      final controller = buildController();
      final line = _line('D', ['e4', 'e5', 'Nf3', 'Nc6']);
      controller.lines = [line];
      controller.reviewMap['D'] = _entry('', 'D'); // reviewed → drilling

      controller.startLine(line);
      await _waitFor(() => controller.waitingForUser);

      expect(controller.phase, TrainingPhase.drilling);
      expect(controller.hadLearnPhaseThisSession, isFalse);
      expect(controller.currentMoveIndex, 0);

      // Correct move: pair completes, opponent replies, next prompt lands.
      await controller.handleUserMove(_move(uci: 'e2e4', san: 'e4'));
      expect(controller.currentMoveIndex, 2);
      expect(controller.waitingForUser, isTrue);
      expect(controller.currentPairOpponent!.san, 'e5');
      expect(controller.lineHadMistake, isFalse);

      // Wrong move: mistake recorded, correction plays out, line finishes
      // into the replay phase (wrongMoveReplay is on).
      await controller.handleUserMove(_move(uci: 'g1h3', san: 'Nh3'));
      expect(controller.lineHadMistake, isTrue);
      expect(controller.wrongMoveIndices, [2]);
      expect(controller.phase, TrainingPhase.replaying);
      expect(controller.waitingForUser, isTrue);
      expect(controller.feedback, contains('Replay'));
      expect(
        controller.session.moveHistory,
        ['e4', 'e5'],
        reason: 'replay rewinds the board to just before the missed move',
      );

      // Wrong replay attempt: stays in replay with a retry prompt.
      await controller.handleUserMove(_move(uci: 'g1h3', san: 'Nh3'));
      expect(controller.phase, TrainingPhase.replaying);
      expect(controller.feedback, 'Try again — the move is Nf3');

      // Correct replay: line is finished and awaits a rating.
      await controller.handleUserMove(_move(uci: 'g1f3', san: 'Nf3'));
      expect(controller.phase, TrainingPhase.finished);
      expect(controller.waitingForUser, isFalse);
      expect(controller.feedback, 'Line complete — rate your recall.');

      await controller.rateLine(ReviewRating.good);
      expect(controller.sessionIncorrect, 1);
      expect(controller.sessionCorrect, 0);
      expect(controller.sessionStreak, 0);
      expect(controller.reviewMap['D']!.failCount, 1);
      expect(controller.reviewMap['D']!.lastRating, 'good');
      expect(reviewService.history, hasLength(1));
      expect(reviewService.history.single.hadMistake, isTrue);
      expect(repService.headerUpdates, ['D']);
      controller.dispose();
    });

    test(
      'a clean drilled line finishes without replay and rates as a pass',
      () async {
        final controller = buildController();
        final line = _line('O', ['e4', 'e5']);
        controller.lines = [line];
        controller.reviewMap['O'] = _entry('', 'O');

        controller.startLine(line);
        await _waitFor(() => controller.waitingForUser);

        await controller.handleUserMove(_move(uci: 'e2e4', san: 'e4'));
        await _waitFor(() => controller.phase == TrainingPhase.finished);
        expect(controller.lineHadMistake, isFalse);
        expect(controller.wrongMoveIndices, isEmpty);
        expect(controller.feedback, 'Line complete — rate your recall.');

        await controller.rateLine(ReviewRating.good);
        expect(controller.sessionCorrect, 1);
        expect(controller.sessionStreak, 1);
        expect(controller.sessionBestStreak, 1);
        expect(controller.reviewMap['O']!.passCount, 1);
        controller.dispose();
      },
    );
  });

  group('learn phase', () {
    test(
      'new line walks through, quizzes after acknowledge, then drills',
      () async {
        final controller = buildController();
        final line = _line('L', ['e4', 'e5']);
        controller.lines = [line];
        // No review entry → the line is new → learning phase.

        controller.startLine(line);
        expect(controller.phase, TrainingPhase.learning);
        expect(controller.hadLearnPhaseThisSession, isTrue);

        await _waitFor(() => controller.learnWaitingForAck);
        expect(controller.currentPairUser!.san, 'e4');
        expect(controller.session.moveHistory, ['e4']);

        controller.learnAcknowledged();
        expect(controller.learnQuizzing, isTrue);
        expect(controller.waitingForUser, isTrue);
        expect(controller.feedback, 'Your move');
        expect(
          controller.session.moveHistory,
          isEmpty,
          reason: 'board rewound',
        );

        await controller.handleUserMove(_move(uci: 'e2e4', san: 'e4'));
        // Walkthrough completes (opponent e5 auto-plays), then the same line
        // restarts in drilling.
        await _waitFor(
          () =>
              controller.phase == TrainingPhase.drilling &&
              controller.waitingForUser,
        );
        expect(controller.currentMoveIndex, 0);
        expect(controller.hadLearnPhaseThisSession, isTrue);
        controller.dispose();
      },
    );

    test('a commented opponent move waits for acknowledgement', () async {
      final controller = buildController();
      final line = _line('M', ['e4', 'e5'], comments: {'1': 'Classic'});
      controller.lines = [line];

      controller.startLine(line);
      await _waitFor(() => controller.learnWaitingForAck);
      controller.learnAcknowledged();
      await controller.handleUserMove(_move(uci: 'e2e4', san: 'e4'));

      // The opponent reply carries prose, so the walkthrough gates on Next.
      expect(controller.opponentWaitingForAck, isTrue);
      expect(controller.currentAnnotation, 'Classic');
      expect(controller.currentPairOpponent!.san, 'e5');

      controller.opponentAcknowledged();
      expect(controller.opponentWaitingForAck, isFalse);
      // Acknowledging finishes the walkthrough and restarts in drilling.
      await _waitFor(
        () =>
            controller.phase == TrainingPhase.drilling &&
            controller.waitingForUser,
      );
      controller.dispose();
    });
  });

  group('session statistics', () {
    test('rateLine tracks correct/incorrect, streak and best streak', () async {
      final controller = buildController();
      final line = _line('S', ['e4']);
      controller.lines = [line];
      controller.reviewMap['S'] = _entry('', 'S');
      controller.startLine(line);
      await _waitFor(() => controller.waitingForUser);

      controller.lineHadMistake = false;
      await controller.rateLine(ReviewRating.good);
      controller.lineHadMistake = false;
      await controller.rateLine(ReviewRating.good);
      expect(controller.sessionCorrect, 2);
      expect(controller.sessionStreak, 2);
      expect(controller.sessionBestStreak, 2);

      controller.lineHadMistake = true;
      await controller.rateLine(ReviewRating.good);
      expect(controller.sessionIncorrect, 1);
      expect(controller.sessionStreak, 0, reason: 'mistake resets the streak');
      expect(controller.sessionBestStreak, 2, reason: 'best streak survives');

      controller.lineHadMistake = false;
      await controller.rateLine(ReviewRating.good);
      expect(controller.sessionCorrect, 3);
      expect(controller.sessionStreak, 1);
      expect(controller.sessionBestStreak, 2);
      controller.dispose();
    });
  });

  group('move progress', () {
    test('streak accumulates to learned and a miss resets it', () {
      final controller = buildController()
        ..settings = _fastSettings(correctStreakThreshold: 2);
      final line = _line('X', ['e4']);

      controller.updateMoveProgress(line, 0, wasCorrect: true);
      expect(controller.moveProgressMap['X:0']!.correctStreak, 1);
      expect(controller.moveProgressMap['X:0']!.learned, isFalse);
      expect(controller.moveDifficulty(line, 0), 0.5);

      controller.updateMoveProgress(line, 0, wasCorrect: true);
      expect(controller.moveProgressMap['X:0']!.correctStreak, 2);
      expect(controller.moveProgressMap['X:0']!.learned, isTrue);

      controller.updateMoveProgress(line, 0, wasCorrect: false);
      expect(controller.moveProgressMap['X:0']!.correctStreak, 0);
      expect(controller.moveProgressMap['X:0']!.learned, isFalse);
      controller.dispose();
    });
  });

  group('training modes', () {
    test('tactics mode drills a new line cold — no learn phase', () async {
      final controller = buildController();
      final line = _line('T', ['e4', 'e5']);
      controller.lines = [line];
      // No review entry → the line is "new", but tactics mode must not
      // reveal the solution via the learn walkthrough.
      controller.trainingMode = TrainingMode.tactics;

      controller.startLine(line);
      expect(controller.phase, TrainingPhase.drilling);
      expect(controller.hadLearnPhaseThisSession, isFalse);
      await _waitFor(() => controller.waitingForUser);
      expect(controller.currentMoveIndex, 0);
      controller.dispose();
    });

    test('tactics mode never auto-plays intro moves', () async {
      final controller = buildController()
        ..settings = _fastSettings()
        ..settings.skipToFirstComment = true;
      final line = _line(
        'T2',
        ['e4', 'e5', 'Nf3'],
        comments: {'2': 'The point.'},
      );
      controller.lines = [line];
      controller.reviewMap['T2'] = _entry('', 'T2');

      // Repertoire mode skips ahead to the first commented move…
      controller.startLine(line);
      expect(controller.trainingStartIndex, 2);

      // …tactics mode starts at the puzzle position, always.
      controller.trainingMode = TrainingMode.tactics;
      controller.startLine(line);
      expect(controller.trainingStartIndex, 0);
      await _waitFor(() => controller.waitingForUser);
      expect(controller.session.moveHistory, isEmpty);
      controller.dispose();
    });

    test('setStudySource defaults to tactics + linear; setRepertoire resets '
        'to repertoire + spaced', () {
      final controller = buildController();

      controller.setStudySource(meta());
      expect(controller.sourceIsStudy, isTrue);
      expect(controller.trainingMode, TrainingMode.tactics);
      expect(controller.repetitionMode, RepetitionMode.linear);

      controller.setRepertoire(meta());
      expect(controller.sourceIsStudy, isFalse);
      expect(controller.trainingMode, TrainingMode.repertoire);
      expect(controller.repetitionMode, RepetitionMode.spaced);
      controller.dispose();
    });
  });

  group('linear repetition', () {
    test('queue includes non-due lines; a completed line drops out with '
        'pass/fail recorded but no SRS scheduling', () async {
      repService.lines = [
        _line('A', ['e4']),
        _line('B', ['d4']),
      ];
      // A is scheduled far in the future — spaced mode would skip it.
      final farDue = DateTime.now().toUtc().add(const Duration(days: 30));
      reviewService.entries = [_entry(repPath(), 'A', due: farDue)];

      final controller = buildController()
        ..settings = _fastSettings(autoNext: false)
        ..setStudySource(meta());
      await controller.loadRepertoire();
      controller.pickStartingLine();

      // Linear ignores due dates: both lines queue in file order.
      expect(controller.dueQueue.map((l) => l.id), ['A', 'B']);
      expect(controller.currentLine!.id, 'A');
      expect(controller.phase, TrainingPhase.drilling);
      await _waitFor(() => controller.waitingForUser);

      await controller.handleUserMove(_move(uci: 'e2e4', san: 'e4'));
      await _waitFor(() => controller.phase == TrainingPhase.finished);
      expect(controller.feedback, 'Puzzle solved!');

      // The finished line left the queue; stats recorded, no scheduling.
      expect(controller.dueQueue.map((l) => l.id), ['B']);
      await _waitFor(() => reviewService.history.length == 1);
      expect(reviewService.history.single.sessionType, 'linear');
      expect(reviewService.history.single.hadMistake, isFalse);
      expect(controller.reviewMap['A']!.passCount, 1);
      expect(
        controller.reviewMap['A']!.lastRating,
        'good',
        reason: 'linear completion must not touch the SRS rating',
      );
      expect(
        controller.reviewMap['A']!.dueDateUtc,
        farDue,
        reason: 'linear completion must not reschedule the line',
      );
      expect(controller.sessionCorrect, 1);
      expect(
        repService.headerUpdates,
        isEmpty,
        reason: 'no SRS headers written in linear mode',
      );

      // Next line, solve it too → the set is complete.
      controller.nextLine();
      await _waitFor(() => controller.waitingForUser);
      expect(controller.currentLine!.id, 'B');
      await controller.handleUserMove(_move(uci: 'd2d4', san: 'd4'));
      await _waitFor(() => controller.phase == TrainingPhase.finished);
      expect(controller.dueQueue, isEmpty);

      controller.nextLine();
      expect(controller.feedback, 'Set complete!');
      controller.dispose();
    });

    test('a mistake in linear mode counts as a fail', () async {
      repService.lines = [
        _line('A', ['e4']),
      ];
      final controller = buildController()
        ..settings = _fastSettings(wrongMoveReplay: false, autoNext: false)
        ..setStudySource(meta());
      await controller.loadRepertoire();
      controller.pickStartingLine();
      await _waitFor(() => controller.waitingForUser);

      await controller.handleUserMove(_move(uci: 'd2d4', san: 'd4'));
      await _waitFor(() => controller.phase == TrainingPhase.finished);
      expect(controller.feedback, 'Solved — with mistakes.');
      await _waitFor(() => reviewService.history.length == 1);
      expect(controller.reviewMap['A']!.failCount, 1);
      expect(controller.sessionIncorrect, 1);
      controller.dispose();
    });

    test('rateLine in linear mode only advances — no scheduling', () async {
      repService.lines = [
        _line('A', ['e4']),
        _line('B', ['d4']),
      ];
      final controller = buildController()
        ..settings = _fastSettings(autoNext: false)
        ..setStudySource(meta());
      await controller.loadRepertoire();
      controller.pickStartingLine();
      await _waitFor(() => controller.waitingForUser);

      await controller.handleUserMove(_move(uci: 'e2e4', san: 'e4'));
      await _waitFor(() => controller.phase == TrainingPhase.finished);

      await controller.rateLine(ReviewRating.good);
      expect(controller.currentLine!.id, 'B');
      expect(controller.reviewMap['A']!.lastRating, '');
      expect(controller.reviewMap['A']!.dueDateUtc, isNull);
      controller.dispose();
    });

    test('switching repetition mode rebuilds the queue', () async {
      repService.lines = [
        _line('A', ['e4']),
      ];
      reviewService.entries = [
        _entry(
          repPath(),
          'A',
          due: DateTime.now().toUtc().add(const Duration(days: 30)),
        ),
      ];
      final controller = buildController()..setRepertoire(meta());
      await controller.loadRepertoire();

      // Spaced: A is not due → empty queue.
      expect(controller.dueQueue, isEmpty);

      controller.setRepetitionMode(RepetitionMode.linear);
      expect(controller.dueQueue.map((l) => l.id), ['A']);

      controller.setRepetitionMode(RepetitionMode.spaced);
      expect(controller.dueQueue, isEmpty);
      controller.dispose();
    });
  });

  group('dispose safety', () {
    test(
      'dispose during an in-flight load completes without throwing',
      () async {
        repService.lines = [
          _line('A', ['e4', 'e5']),
        ];
        reviewService.loadDelay = const Duration(milliseconds: 30);
        final controller = buildController()..setRepertoire(meta());

        final load = controller.loadRepertoire();
        controller.dispose();

        await expectLater(load, completes);
        // Late async completions (queue build, startLine notifications) are
        // swallowed by SafeChangeNotifier; give them time to land.
        await Future<void>.delayed(const Duration(milliseconds: 60));
      },
    );

    test('dispose mid-line leaves pending pacing futures harmless', () async {
      final controller = buildController();
      final line = _line('D', ['e4', 'e5', 'Nf3']);
      controller.lines = [line];
      controller.reviewMap['D'] = _entry('', 'D');

      controller.startLine(line);
      controller.dispose();

      // The startLine microtask and its 1 ms pacing delays resolve after
      // dispose; SafeChangeNotifier must swallow their notifications.
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
  });
}
