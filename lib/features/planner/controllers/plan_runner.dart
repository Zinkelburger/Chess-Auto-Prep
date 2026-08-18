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

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../constants/chess_constants.dart';
import '../../../core/generation_session_controller.dart';
import '../../../services/generation/generation_config.dart';
import '../../../utils/chess_utils.dart';
import '../../repertoire/services/repertoire_outline_service.dart';
import '../models/plan_models.dart';

enum PlanChapterStatus { pending, creating, building, done, skipped, failed }

class PlanChapterProgress {
  final PlanChapter chapter;
  PlanChapterStatus status;
  String? path;
  String? error;
  PlanChapterProgress(this.chapter) : status = PlanChapterStatus.pending;
}

class PlanRunner extends ChangeNotifier {
  PlanRunner({required this.generation, RepertoireOutlineService? outline})
    : _outline = outline ?? RepertoireOutlineService();

  final GenerationSessionController generation;
  final RepertoireOutlineService _outline;

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
    config = config.copyWith(
      skeletonPlan: withPlanLines(config.skeletonPlan, plan),
    );
    _items
      ..clear()
      ..addAll(plan.chapters.map(PlanChapterProgress.new));
    _current = -1;
    notifyListeners();

    try {
      // Phase 1: files.
      for (final item in _items) {
        if (_cancelled) break;
        item.status = PlanChapterStatus.creating;
        notifyListeners();
        try {
          item.path = await _createChapter(
            folderPath,
            item.chapter,
            plan.isWhite,
          );
          item.status = generate
              ? PlanChapterStatus.pending
              : PlanChapterStatus.done;
          onChapterChanged?.call(item.path!);
        } catch (e) {
          item.status = PlanChapterStatus.failed;
          item.error = '$e';
        }
        notifyListeners();
      }
      if (!generate) return;

      // Phase 2: builds, in order.
      for (var i = 0; i < _items.length; i++) {
        if (_cancelled) break;
        final item = _items[i];
        if (item.path == null || item.status == PlanChapterStatus.failed) {
          continue;
        }
        _current = i;
        item.status = PlanChapterStatus.building;
        notifyListeners();
        try {
          await _build(item, plan.isWhite, config);
          if (item.status == PlanChapterStatus.building) {
            item.status = _cancelled
                ? PlanChapterStatus.skipped
                : PlanChapterStatus.done;
          }
        } catch (e) {
          item.status = PlanChapterStatus.failed;
          item.error = '$e';
        }
        onChapterChanged?.call(item.path!);
        notifyListeners();
      }
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

  Future<String> _createChapter(
    String folderPath,
    PlanChapter chapter,
    bool isWhite,
  ) async {
    var name = _safeName(chapter.name);
    var attempt = 1;
    while (true) {
      try {
        final created = await _outline.createChapter(
          folderPath: folderPath,
          name: name,
          isWhite: isWhite,
        );
        return created.path;
      } on OutlineEditException catch (e) {
        if (!e.message.contains('already exists') || attempt > 20) rethrow;
        attempt++;
        name = '${_safeName(chapter.name)} ($attempt)';
      }
    }
  }

  static String _safeName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? 'Chapter' : cleaned;
  }

  /// One engine build per build point, all into the chapter's file.
  Future<void> _build(
    PlanChapterProgress item,
    bool isWhite,
    TreeBuildConfig config,
  ) async {
    for (final point in item.chapter.points) {
      if (_cancelled || item.status != PlanChapterStatus.building) return;
      final fen = _fenAfter(point.moves);
      if (fen == null) {
        throw StateError('Path is not playable: ${point.moves}');
      }
      final request = GenerationRequest(
        config: config.copyWith(
          startFen: fen,
          playAsWhite: isWhite,
          rootReplyExclude: point.excludeReplies,
        ),
        repertoireFilePath: item.path!,
        buildRootFen: fen,
        lineMovePrefix: List.unmodifiable(point.moves),
        repertoireStartFen: kStandardStartFen,
        onLinesSaved: (_) {},
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

  static String? _fenAfter(List<String> moves) {
    try {
      Position pos = Chess.initial;
      for (final san in moves) {
        final next = playSanOrNullMove(pos, san);
        if (next == null) return null;
        pos = next;
      }
      return pos.fen;
    } catch (_) {
      return null;
    }
  }

  /// The form's skeleton plus one line per planned chapter (its move path).
  static SkeletonPlan withPlanLines(SkeletonPlan base, RepertoirePlan plan) {
    final lines = [
      for (final c in plan.chapters)
        for (final path in c.buildPaths)
          if (path.isNotEmpty) path.join(' '),
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
      if (item.path != null && p.equals(item.path!, chapterPath)) {
        return switch (item.status) {
          PlanChapterStatus.pending => 'queued',
          PlanChapterStatus.creating => 'creating…',
          PlanChapterStatus.building => 'building…',
          PlanChapterStatus.done => null,
          PlanChapterStatus.skipped => 'skipped',
          PlanChapterStatus.failed => 'failed',
        };
      }
    }
    return null;
  }
}
