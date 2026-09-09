import 'dart:async';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generation_session_controller.dart';
import 'package:chess_auto_prep/features/planner/controllers/plan_runner.dart';
import 'package:chess_auto_prep/features/planner/models/plan_models.dart';
import 'package:chess_auto_prep/features/repertoire/models/repertoire_outline.dart';
import 'package:chess_auto_prep/features/repertoire/services/repertoire_outline_service.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// [PlanRunner] sequencing: chapter files first, then one build per build
/// point, with cancel / skip / refusal / unplayable-path handling. The
/// skeleton-plan merge is covered in plan_runner_skeleton_test.dart.

/// Records every build request; each build waits until [release] (or
/// [cancelBuild]) and then reports [refuseWith] through [lastError].
class _FakeGeneration extends GenerationSessionController {
  final List<GenerationRequest> requests = [];
  bool _generating = false;
  Completer<void>? _build;
  int cancels = 0;

  /// Set to make the *next* build a refusal.
  String? refuseWith;

  /// When true, builds finish on their own; otherwise [release] ends one.
  bool autoFinish = true;

  @override
  bool get isGenerating => _generating;

  @override
  Future<void> startBuild(GenerationRequest request) async {
    if (_generating) return;
    requests.add(request);
    _generating = true;
    lastError = null;
    if (!autoFinish) {
      _build = Completer<void>();
      await _build!.future;
    } else {
      await Future<void>.delayed(Duration.zero);
    }
    lastError = refuseWith;
    refuseWith = null;
    _generating = false;
  }

  @override
  void cancelBuild() {
    cancels++;
    if (_build != null && !_build!.isCompleted) _build!.complete();
  }

  /// Let the current (held) build finish normally.
  void release() {
    if (_build != null && !_build!.isCompleted) _build!.complete();
  }
}

/// Creates nothing on disk: records the names asked for and can refuse a
/// name a set number of times as "already exists".
class _FakeOutline implements RepertoireOutlineService {
  final List<String> names = [];
  final Map<String, int> collisions = {};

  /// Makes the next creation fail with this message, once.
  String? failNextWith;

  @override
  Future<OutlineChapter> createChapter({
    required String folderPath,
    required String name,
    required bool isWhite,
  }) async {
    final fail = failNextWith;
    if (fail != null) {
      failNextWith = null;
      throw OutlineEditException(fail);
    }
    final left = collisions[name] ?? 0;
    if (left > 0) {
      collisions[name] = left - 1;
      throw const OutlineEditException(
        'A chapter with that name already exists.',
      );
    }
    names.add(name);
    return OutlineChapter(path: '$folderPath/$name.pgn', name: name);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _fenAfter(List<String> sans) {
  Position pos = Chess.initial;
  for (final san in sans) {
    pos = playSanOrNullMove(pos, san)!;
  }
  return pos.fen;
}

const _config = TreeBuildConfig(startFen: kStandardStartFen, playAsWhite: true);

RepertoirePlan _plan({bool isWhite = false, List<PlanChapter>? chapters}) =>
    RepertoirePlan(
      isWhite: isWhite,
      elo: 1800,
      minShare: 0.05,
      chapters:
          chapters ??
          [
            PlanChapter(
              name: "Queen's Gambit Declined: 3.Nc3",
              family: "Queen's Gambit Declined",
              moves: ['d4', 'd5', 'c4', 'e6'],
              points: [
                const PlanBuildPoint(
                  moves: ['d4', 'd5', 'c4', 'e6', 'Nc3'],
                  excludeReplies: ['Nf6'],
                ),
                const PlanBuildPoint(moves: ['d4', 'd5', 'c4', 'e6', 'Nf3']),
              ],
            ),
            PlanChapter(
              name: 'London System',
              family: 'London System',
              moves: ['d4', 'd5', 'Bf4'],
              points: [
                const PlanBuildPoint(moves: ['d4', 'd5', 'Bf4']),
              ],
            ),
          ],
    );

void main() {
  late _FakeGeneration generation;
  late _FakeOutline outline;
  late PlanRunner runner;

  setUp(() {
    generation = _FakeGeneration();
    outline = _FakeOutline();
    runner = PlanRunner(generation: generation, outline: outline);
  });

  tearDown(() {
    runner.dispose();
    generation.dispose();
  });

  test('creates every chapter file with a file-safe name, in order', () async {
    final changed = <String>[];
    runner.onChapterChanged = changed.add;
    await runner.run(
      plan: _plan(),
      folderPath: '/rep',
      config: _config,
      generate: false,
    );
    // The colon in the book name cannot be in a file name.
    expect(outline.names, ["Queen's Gambit Declined 3.Nc3", 'London System']);
    expect(
      runner.items.map((i) => i.status),
      everyElement(PlanChapterStatus.done),
    );
    expect(runner.items.map((i) => i.path), [
      "/rep/Queen's Gambit Declined 3.Nc3.pgn",
      '/rep/London System.pgn',
    ]);
    expect(changed, runner.items.map((i) => i.path).toList());
    expect(generation.requests, isEmpty);
    expect(runner.isRunning, isFalse);
    expect(runner.doneCount, 2);
  });

  test('a name that already exists gets a numbered suffix', () async {
    outline.collisions['London System'] = 1;
    outline.collisions['London System (2)'] = 1;
    await runner.run(
      plan: _plan(),
      folderPath: '/rep',
      config: _config,
      generate: false,
    );
    expect(outline.names.last, 'London System (3)');
    expect(runner.items.last.status, PlanChapterStatus.done);
  });

  test('a name of only illegal characters becomes "Chapter"', () async {
    await runner.run(
      plan: _plan(
        chapters: [
          PlanChapter(name: '<>:"?*', family: 'x', moves: [], points: []),
        ],
      ),
      folderPath: '/rep',
      config: _config,
      generate: false,
    );
    expect(outline.names, ['Chapter']);
  });

  test('a chapter that cannot be created fails; the rest still run', () async {
    outline.failNextWith = 'disk full';
    await runner.run(plan: _plan(), folderPath: '/rep', config: _config);
    expect(runner.items.first.status, PlanChapterStatus.failed);
    expect(runner.items.first.error, contains('disk full'));
    expect(runner.items.first.path, isNull);
    expect(runner.items.last.status, PlanChapterStatus.done);
    // Only the London chapter was built.
    expect(generation.requests.map((r) => r.repertoireFilePath), [
      '/rep/London System.pgn',
    ]);
  });

  test('builds one request per build point, rooted at its position', () async {
    await runner.run(plan: _plan(), folderPath: '/rep', config: _config);
    expect(generation.requests, hasLength(3));
    final first = generation.requests.first;
    expect(first.config.startFen, _fenAfter(['d4', 'd5', 'c4', 'e6', 'Nc3']));
    expect(first.buildRootFen, first.config.startFen);
    // The plan's colour overrides the form's colour.
    expect(first.config.playAsWhite, isFalse);
    expect(first.config.rootReplyExclude, ['Nf6']);
    expect(first.lineMovePrefix, ['d4', 'd5', 'c4', 'e6', 'Nc3']);
    expect(first.repertoireStartFen, kStandardStartFen);
    expect(first.repertoireFilePath, "/rep/Queen's Gambit Declined 3.Nc3.pgn");
    // Every chapter's line is a skeleton pin for every build.
    expect(
      first.config.skeletonPlan.sourceLines,
      containsAll(['d4 d5 c4 e6 Nc3', 'd4 d5 Bf4']),
    );
    expect(generation.requests[1].config.rootReplyExclude, isEmpty);
    expect(generation.requests[2].repertoireFilePath, '/rep/London System.pgn');
    expect(
      runner.items.map((i) => i.status),
      everyElement(PlanChapterStatus.done),
    );
    expect(runner.currentIndex, -1);
  });

  test(
    'an unplayable path fails its chapter and the next one builds',
    () async {
      await runner.run(
        plan: _plan(
          chapters: [
            PlanChapter(
              name: 'Broken',
              family: 'x',
              moves: [],
              points: [
                const PlanBuildPoint(moves: ['d4', 'Kxe8']),
              ],
            ),
            PlanChapter(
              name: 'Fine',
              family: 'x',
              moves: [],
              points: [
                const PlanBuildPoint(moves: ['d4']),
              ],
            ),
          ],
        ),
        folderPath: '/rep',
        config: _config,
      );
      expect(runner.items.first.status, PlanChapterStatus.failed);
      expect(runner.items.first.error, contains('not playable'));
      expect(runner.items.last.status, PlanChapterStatus.done);
      expect(generation.requests.single.lineMovePrefix, ['d4']);
    },
  );

  test('a refused build fails the chapter with the refusal text', () async {
    generation.refuseWith = 'Engine not found.';
    await runner.run(plan: _plan(), folderPath: '/rep', config: _config);
    final qgd = runner.items.first;
    expect(qgd.status, PlanChapterStatus.failed);
    expect(qgd.error, 'Engine not found.');
    // The failed chapter's second point is not attempted; the next chapter is.
    expect(generation.requests, hasLength(2));
    expect(runner.items.last.status, PlanChapterStatus.done);
    expect(runner.statusLabelFor(qgd.path!), 'failed');
    expect(runner.statusLabelFor(runner.items.last.path!), isNull);
  });

  test('cancel() stops the current build and starts no other', () async {
    generation.autoFinish = false;
    final labels = <String?>[];
    runner.addListener(() {
      if (runner.isRunning && runner.currentIndex >= 0) {
        labels.add(
          runner.statusLabelFor(runner.items[runner.currentIndex].path!),
        );
      }
    });
    final running = runner.run(
      plan: _plan(),
      folderPath: '/rep',
      config: _config,
    );
    // Files exist, first build is in flight.
    while (generation.requests.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(runner.isRunning, isTrue);
    expect(runner.currentIndex, 0);
    expect(labels, contains('building…'));

    runner.cancel();
    await running;
    expect(generation.cancels, 1);
    expect(generation.requests, hasLength(1));
    expect(runner.items[0].status, PlanChapterStatus.skipped);
    expect(runner.items[0].error, isNull);
    expect(runner.isRunning, isFalse);
    expect(runner.currentIndex, -1);
    // The chapter never reached still says "queued" (its file exists).
    expect(runner.items[1].status, PlanChapterStatus.pending);
    expect(runner.statusLabelFor(runner.items[1].path!), 'queued');
  });

  test('skipCurrent() abandons that chapter and the next one builds', () async {
    generation.autoFinish = false;
    final running = runner.run(
      plan: _plan(),
      folderPath: '/rep',
      config: _config,
    );
    while (generation.requests.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    runner.skipCurrent();
    expect(runner.items[0].status, PlanChapterStatus.skipped);
    // Second chapter starts on its own; let it finish.
    while (generation.requests.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(runner.currentIndex, 1);
    generation.release();
    await running;
    // The skipped chapter's second point was never built.
    expect(generation.requests.map((r) => r.repertoireFilePath), [
      "/rep/Queen's Gambit Declined 3.Nc3.pgn",
      '/rep/London System.pgn',
    ]);
    expect(runner.items[0].status, PlanChapterStatus.skipped);
    expect(runner.items[1].status, PlanChapterStatus.done);
    expect(runner.doneCount, 1);
  });

  test('a second run() while one is running is ignored', () async {
    generation.autoFinish = false;
    final running = runner.run(
      plan: _plan(),
      folderPath: '/rep',
      config: _config,
    );
    while (generation.requests.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await runner.run(plan: _plan(), folderPath: '/other', config: _config);
    expect(outline.names, hasLength(2)); // no second set of files
    runner.cancel();
    await running;
  });

  test(
    'a build already running elsewhere fails the chapter, not the run',
    () async {
      generation._generating = true; // someone else's build
      await runner.run(plan: _plan(), folderPath: '/rep', config: _config);
      expect(
        runner.items.map((i) => i.status),
        everyElement(PlanChapterStatus.failed),
      );
      expect(runner.items.first.error, contains('already running'));
      expect(generation.requests, isEmpty);
      expect(runner.isRunning, isFalse);
    },
  );
}
