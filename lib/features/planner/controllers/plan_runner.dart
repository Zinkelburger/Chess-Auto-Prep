/// Turns a [RepertoirePlan] into chapter files and runs one engine build per
/// chapter, in order, through the app's [GenerationSessionController] — so
/// each chapter is an ordinary job (pause, cancel, jobs panel) and lines land
/// in the chapter's own file exactly as a hand-started build would put them.
///
/// The runner owns the sequence, not the builds. It survives the planning
/// screen closing: the user can go back to the builder and watch chapters
/// fill in from the outline.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../constants/chess_constants.dart';
import '../../../core/generation_session_controller.dart';
import '../../../core/generation_session_types.dart';
import '../../../services/generation/generation_config.dart';
import '../../../utils/safe_change_notifier.dart';
import '../../repertoire/services/course_chapter_partition.dart';
import '../../repertoire/services/repertoire_outline_service.dart';
import '../models/plan_models.dart';
import '../services/san_paths.dart';

enum PlanChapterStatus {
  pending('queued'),
  creating('creating…'),
  building('building…'),
  done(null),
  skipped('skipped'),
  failed('failed');

  const PlanChapterStatus(this.label);

  /// What the outline badges the chapter with; nothing once it is done.
  final String? label;
}

/// Where one planned chapter is in the run. Mutable: the runner advances it
/// in place and notifies.
class PlanChapterProgress {
  final PlanChapter chapter;
  PlanChapterStatus status = PlanChapterStatus.pending;

  /// The chapter file, once created.
  String? path;
  String? error;
  PlanChapterProgress(this.chapter);
}

class PlanRunner extends ChangeNotifier with SafeChangeNotifier {
  PlanRunner({required this.generation, required this._outline});

  final GenerationSessionController generation;
  final RepertoireOutlineService _outline;

  /// How many numbered suffixes to try before giving up on a taken name.
  static const int _maxNameAttempts = 20;

  final List<PlanChapterProgress> _items = [];
  List<PlanChapterProgress> get items => List.unmodifiable(_items);

  bool _running = false;
  bool get isRunning => _running;
  bool _cancelled = false;
  int _current = -1;
  int get currentIndex => _current;

  int get doneCount =>
      _items.where((i) => i.status == PlanChapterStatus.done).length;

  /// Called after each chapter file is created and after each build ends,
  /// so the outline can refresh.
  void Function(String chapterPath)? onChapterChanged;

  /// Create every chapter file up front (so the outline shows the whole plan
  /// at once), then build them one after another.
  ///
  /// [config] is the engine configuration to use for every chapter; start
  /// position, colour and root exclusions are set per chapter here.
  Future<void> run({
    required RepertoirePlan plan,
    required String folderPath,
    required TreeBuildConfig config,
    bool generate = true,
  }) async {
    if (_running) return;
    _running = true;
    _cancelled = false;
    // Every chapter's move path is a line the user chose; its our-moves are
    // pins, and across chapters they are transfer targets — so the London
    // chapter answers 2.Bf4 the way the QGD chapter answered 2.c4 unless the
    // engine has a strong reason not to. Anything the user typed into the
    // form's own skeleton card is kept.
    final buildConfig = config.copyWith(
      skeletonPlan: withPlanLines(config.skeletonPlan, plan),
    );
    _items
      ..clear()
      ..addAll(plan.chapters.map(PlanChapterProgress.new));
    _current = -1;
    notifyListeners();

    try {
      await _createChapterFiles(plan, folderPath, generate: generate);
      if (!generate) return;
      await _buildChapters(plan, buildConfig);
    } finally {
      _running = false;
      _current = -1;
      notifyListeners();
    }
  }

  /// Stop after the current chapter's build ends (and cancel that build).
  void cancel() {
    _cancelled = true;
    if (generation.isGenerating) generation.cancelBuild();
    notifyListeners();
  }

  /// Skip the chapter currently building; the next one starts.
  void skipCurrent() {
    if (_current < 0 || _current >= _items.length) return;
    _items[_current].status = PlanChapterStatus.skipped;
    if (generation.isGenerating) generation.cancelBuild();
    notifyListeners();
  }

  /// Phase 1: files. A chapter that cannot be created fails on its own; the
  /// rest are still made.
  Future<void> _createChapterFiles(
    RepertoirePlan plan,
    String folderPath, {
    required bool generate,
  }) async {
    for (final item in _items) {
      if (_cancelled) break;
      item.status = PlanChapterStatus.creating;
      notifyListeners();
      try {
        final path = await _createChapter(
          folderPath,
          item.chapter,
          plan.isWhite,
        );
        item.path = path;
        item.status = generate
            ? PlanChapterStatus.pending
            : PlanChapterStatus.done;
        onChapterChanged?.call(path);
      } catch (e) {
        item.status = PlanChapterStatus.failed;
        item.error = '$e';
      }
      notifyListeners();
    }
  }

  /// Phase 2: builds, in order, skipping chapters without a file.
  Future<void> _buildChapters(
    RepertoirePlan plan,
    TreeBuildConfig config,
  ) async {
    for (var i = 0; i < _items.length; i++) {
      if (_cancelled) break;
      final item = _items[i];
      final path = item.path;
      if (path == null || item.status == PlanChapterStatus.failed) continue;
      _current = i;
      item.status = PlanChapterStatus.building;
      notifyListeners();
      try {
        await _build(item, path, plan.isWhite, config);
        if (item.status == PlanChapterStatus.building) {
          item.status = _cancelled
              ? PlanChapterStatus.skipped
              : PlanChapterStatus.done;
        }
      } catch (e) {
        item.status = PlanChapterStatus.failed;
        item.error = '$e';
      }
      onChapterChanged?.call(path);
      notifyListeners();
    }
  }

  /// Creates the chapter file, numbering the name past any it collides with.
  Future<String> _createChapter(
    String folderPath,
    PlanChapter chapter,
    bool isWhite,
  ) async {
    final base = CourseChapterPartition.fileNameFor(chapter.name);
    var name = base;
    var attempt = 1;
    while (true) {
      try {
        final created = await _outline.createChapter(
          folderPath: folderPath,
          name: name,
          isWhite: isWhite,
        );
        return created.path;
      } on OutlineNameTakenException {
        if (attempt > _maxNameAttempts) rethrow;
        attempt++;
        name = '$base ($attempt)';
      }
    }
  }

  /// One engine build per build point, all into the chapter's file.
  Future<void> _build(
    PlanChapterProgress item,
    String chapterPath,
    bool isWhite,
    TreeBuildConfig config,
  ) async {
    for (final point in item.chapter.points) {
      if (_cancelled || item.status != PlanChapterStatus.building) return;
      final fen = fenAfterSanPath(point.moves);
      if (fen == null) {
        throw StateError('Path is not playable: ${point.moves}');
      }
      final request = GenerationRequest(
        jobLabel: item.chapter.name,
        config: config.copyWith(
          startFen: fen,
          playAsWhite: isWhite,
          rootReplyExclude: point.excludeReplies,
        ),
        repertoireFilePath: chapterPath,
        buildRootFen: fen,
        lineMovePrefix: List.unmodifiable(point.moves),
        repertoireStartFen: kStandardStartFen,
        onPublished: (_) {},
      );
      if (generation.isGenerating) {
        throw StateError('Another build is already running.');
      }
      generation.lastError = null;
      await generation.startBuild(request);
      final err = generation.lastError;
      if (err != null &&
          err.isNotEmpty &&
          item.status == PlanChapterStatus.building &&
          !_cancelled) {
        // The controller reports refusals through lastError; a cancelled
        // build is not a failure.
        item.status = PlanChapterStatus.failed;
        item.error = err;
        return;
      }
    }
  }

  /// The form's skeleton plus one line per planned chapter (its move path).
  static SkeletonPlan withPlanLines(SkeletonPlan base, RepertoirePlan plan) {
    final lines = [
      for (final c in plan.chapters)
        for (final path in c.buildPaths)
          if (path.isNotEmpty) sanPathKey(path),
    ];
    if (lines.isEmpty) return base;
    final added = SkeletonPlan.fromLines(lines, playAsWhite: plan.isWhite);
    final seen = {for (final n in base.nodes) '${n.fen}|${n.uci}'};
    return SkeletonPlan(
      nodes: [
        ...base.nodes,
        for (final n in added.nodes)
          if (seen.add('${n.fen}|${n.uci}')) n,
      ],
      features: base.features,
      sourceLines: [...base.sourceLines, ...added.sourceLines],
      transferMaxDiff: base.transferMaxDiff,
    );
  }

  /// Chapter path → display name, for the outline to badge progress.
  String? statusLabelFor(String chapterPath) {
    for (final item in _items) {
      final path = item.path;
      if (path != null && p.equals(path, chapterPath)) {
        return item.status.label;
      }
    }
    return null;
  }
}
