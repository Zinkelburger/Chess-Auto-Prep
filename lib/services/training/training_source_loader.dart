/// Turning a training source on disk into lines with their review state.
///
/// Pulled out of [TrainingSessionController.loadRepertoire], which mixed the
/// file work (which chapters to parse, syncing each one's review entries,
/// reading the generated tree for playability) with the session state it
/// installs afterwards. Everything here is the former: the loader never
/// touches the controller and returns one value the owner adopts.
///
/// A source is one of:
///
///  * a repertoire `.pgn` — parsed once; its `<name>_tree.json`, when the
///    generator wrote one, is read separately by [playabilityFromTree] so the
///    owner can show the first queue before the tree is decoded;
///  * a repertoire *folder* — every chapter `.pgn` under it, recursively,
///    each parsed with its own remembered training colour and its lines
///    scoped with [RepertoireLine.inSource] so same-named lines in two
///    chapters stay distinct;
///  * a study — chapters are puzzles, parsed with per-chapter solver colours
///    and no tree.
library;

import 'dart:isolate';

import 'package:flutter/foundation.dart' show debugPrint, listEquals;
import 'package:path/path.dart' as p;

import '../../models/repertoire_line.dart';
import '../../models/repertoire_metadata.dart';
import '../../models/repertoire_move_progress.dart';
import '../../models/repertoire_review_entry.dart' show RepertoireReviewEntry;
import '../asked_questions_store.dart';
import '../generation/tree_my_ease.dart' show computeLinePlayability;
import '../generation/tree_serialization.dart' show deserializeTree;
import '../line_metrics_helpers.dart' show walkTreeForLine;
import '../repertoire_review_service.dart';
import '../repertoire_service.dart';
import '../storage/storage_factory.dart';
import '../storage/storage_service.dart';

/// Everything a training session needs from a freshly loaded source.
class LoadedTrainingSource {
  const LoadedTrainingSource({
    required this.lines,
    required this.reviewByLine,
    required this.moveProgress,
    required this.otherRepertoires,
    required this.isFolder,
  });

  /// Parsed lines in file order. Empty when the source holds nothing to train.
  final List<RepertoireLine> lines;

  /// Review entries keyed by [RepertoireLine.id], synced and already saved.
  final Map<String, RepertoireReviewEntry> reviewByLine;

  /// Per-move streaks keyed `"<lineId>:<moveIndex>"`.
  final Map<String, RepertoireMoveProgress> moveProgress;

  /// Stored entries belonging to sources other than this one.
  final List<RepertoireReviewEntry> otherRepertoires;

  /// True when the source was a folder of chapter files. Folders and studies
  /// have no generated tree, so [TrainingSourceLoader.playabilityFromTree]
  /// only applies to a single repertoire file.
  final bool isFolder;
}

class TrainingSourceLoader {
  TrainingSourceLoader({
    required this.repertoireService,
    required this.reviewService,
    required this.askedQuestions,
    StorageService Function()? storage,
  }) : _storage = storage ?? (() => StorageFactory.instance);

  final RepertoireService repertoireService;
  final RepertoireReviewService reviewService;
  final AskedQuestionsStore askedQuestions;
  final StorageService Function() _storage;

  /// Load [source].
  ///
  /// [colorOverrideIsWhite] is the user's hand-set answer to which side the
  /// file trains; it beats the per-chapter answers and the file's own header.
  /// [isStale] is polled after every await that took real time; when it
  /// reports the load was superseded the loader stops and returns null
  /// without writing anything further. [onStatus] hears what the loader is
  /// doing, in words the owner can show under its spinner.
  Future<LoadedTrainingSource?> load(
    RepertoireMetadata source, {
    required bool isStudy,
    required bool? colorOverrideIsWhite,
    required bool Function() isStale,
    void Function(String status)? onStatus,
  }) async {
    final filePath = source.filePath;
    final isFolder =
        !isStudy && !p.extension(filePath).toLowerCase().endsWith('pgn');
    final sources = isFolder ? await _chapterFiles(filePath) : [source];

    final allEntries = await reviewService.loadAll();
    final progressBySource = <String, List<RepertoireMoveProgress>>{};
    for (final mp in await reviewService.loadMoveProgress()) {
      (progressBySource['${mp.repertoireId}::${mp.lineId}'] ??= []).add(mp);
    }

    final lines = <RepertoireLine>[];
    final reviewByLine = <String, RepertoireReviewEntry>{};
    final moveProgress = <String, RepertoireMoveProgress>{};
    for (final chapter in sources) {
      final chapterIsWhite =
          colorOverrideIsWhite ??
          (isFolder
              ? await askedQuestions.boolAnswerFor(
                  AskedQuestion.trainingColor,
                  subject: chapter.filePath,
                )
              : null);
      onStatus?.call('Preparing lines in ${chapter.name}…');
      final parsed = await repertoireService.parseRepertoireFile(
        chapter.filePath,
        trainingColor: switch (chapterIsWhite) {
          null => null,
          true => 'white',
          false => 'black',
        },
        colorFromStartingSide: isStudy,
        inferColorWhenUnknown: !isStudy,
      );
      if (isStale()) return null;

      final existing = [
        for (final entry in allEntries)
          if (entry.repertoireId == chapter.filePath) entry,
      ];
      final merged = reviewService.syncEntries(
        repertoireId: chapter.filePath,
        lines: parsed,
        existing: existing,
      );
      onStatus?.call('Restoring review progress…');
      // Reopening unchanged material must not rewrite the review store:
      // only save when syncing actually produced different rows.
      if (!listEquals(
        [for (final entry in existing) entry.toCsvRow()],
        [for (final entry in merged) entry.toCsvRow()],
      )) {
        await reviewService.saveAll(merged, repertoireId: chapter.filePath);
        if (isStale()) return null;
      }
      final entriesById = {for (final entry in merged) entry.lineId: entry};
      for (final line in parsed) {
        final scoped = isFolder
            ? line.inSource(chapter.filePath, chapter.name)
            : line;
        lines.add(scoped);
        reviewByLine[scoped.id] = entriesById[line.id]!;
        final key = '${chapter.filePath}::${line.id}';
        for (final mp
            in progressBySource[key] ?? const <RepertoireMoveProgress>[]) {
          moveProgress['${scoped.id}:${mp.moveIndex}'] = mp;
        }
      }
    }
    if (isStale()) return null;

    return LoadedTrainingSource(
      lines: lines,
      reviewByLine: reviewByLine,
      moveProgress: moveProgress,
      otherRepertoires: [
        for (final entry in allEntries)
          if (!sources.any((s) => s.filePath == entry.repertoireId)) entry,
      ],
      isFolder: isFolder,
    );
  }

  /// Every chapter file under [folder], depth first.
  Future<List<RepertoireMetadata>> _chapterFiles(String folder) async {
    final storage = _storage();
    final files = await storage.listChapters(folder);
    for (final child in await storage.listSubdirectories(folder)) {
      files.addAll(await _chapterFiles(child));
    }
    return files;
  }

  /// Per-line playability from the repertoire's generated `<name>_tree.json`,
  /// 0 (hardest) to 1 (easiest), keyed by line id.
  ///
  /// Empty when there is no tree or it cannot be read: playability only
  /// orders the queue, so a broken tree must not block training. Difficulty
  /// is optional builder metadata; the owner calls this after [load] so the
  /// first queue is not held up by decoding a multi-MB tree. [isStale] is
  /// polled between the file read and the decode so a superseded load does
  /// not spin up an isolate for nothing.
  Future<Map<String, double>> playabilityFromTree(
    String filePath,
    List<RepertoireLine> lines, {
    bool Function()? isStale,
  }) async {
    final treePath = '${p.withoutExtension(filePath)}_tree.json';
    final storage = _storage();
    try {
      if (!await storage.fileExists(treePath)) return const {};
      final json = await storage.readFile(treePath);
      if (json == null || json.isEmpty) return const {};
      if (isStale?.call() ?? false) return const {};
      final linePaths = [
        for (final line in lines) (id: line.id, moves: line.moves),
      ];
      // Keep both the decode and the tree walk off the UI isolate so the
      // large tree object never has to cross back to it.
      return await Isolate.run(() => _playabilityScores(json, linePaths));
    } catch (e) {
      debugPrint('[TrainingSourceLoader] Failed to load tree: $e');
      return const {};
    }
  }
}

Map<String, double> _playabilityScores(
  String json,
  List<({String id, List<String> moves})> lines,
) {
  final tree = deserializeTree(json);
  final isWhite = tree.configSnapshot['play_as_white'] as bool? ?? true;
  return {
    for (final line in lines)
      if (walkTreeForLine(tree.root, line.moves) case final path
          when path.length >= 2)
        line.id: computeLinePlayability(path, isWhite).playability,
  };
}
