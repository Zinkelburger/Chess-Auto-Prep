/// The files a generation run keeps beside a repertoire PGN.
///
/// Every artifact is named from the repertoire file path: the serialized
/// tree of the last full build (`_tree.json`), the resumable partial tree of
/// an unfinished build (`_partial_tree.json`), the probe trees of the
/// expectimax database (`_expectimax.json`), the trap index (`_traps.json`)
/// and the model-games companion (`_model_games.pgn`).
///
/// Owned by [GenerationSessionController], which decides *when* each file is
/// written; this class only knows *where* and *how*. Reads and writes go
/// through [StorageFactory] so tests can substitute an in-memory store.
library;

import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../models/build_tree_node.dart';
import '../models/trap_line_info.dart';
import '../services/generation/course/course_builder.dart';
import '../services/generation/course/course_composer.dart';
import '../services/generation/expectimax_probe.dart';
import '../services/generation/trap_extractor.dart';
import '../services/generation/tree_serialization.dart';
import '../services/storage/storage_factory.dart';
import '../services/storage/storage_service.dart';
import '../utils/log.dart';

/// What [GenerationArtifactStore.readDatabase] found on disk.
typedef SavedExpectimaxDatabase = ({BuildTree? tree, List<BuildTree> probes});

class GenerationArtifactStore {
  GenerationArtifactStore({StorageService Function()? storage})
    : _storage = storage ?? _defaultStorage;

  static StorageService _defaultStorage() => StorageFactory.instance;

  static const String _logName = 'GenerationArtifacts';

  final StorageService Function() _storage;

  /// `<repertoire>_tree.json` — the tree of the last full build.
  static String treePathFor(String repertoireFilePath) =>
      '${p.withoutExtension(repertoireFilePath)}_tree.json';

  /// `<repertoire>_partial_tree.json` — an unfinished build to resume.
  static String partialTreePathFor(String repertoireFilePath) =>
      '${p.withoutExtension(repertoireFilePath)}_partial_tree.json';

  /// `<repertoire>_expectimax.json` — the probe trees.
  static String probesPathFor(String repertoireFilePath) =>
      ExpectimaxProbeStore.pathFor(repertoireFilePath);

  /// `<repertoire>_model_games.pgn` — the model games as a game collection.
  static String modelGamesPathFor(String repertoireFilePath) =>
      CourseBuilder.modelGamesPathFor(repertoireFilePath);

  /// Write [tree] as the build's tree file, encoded off the UI isolate.
  ///
  /// Returns the JSON so the caller can reuse it (the run debug dump wants
  /// the same text), or null when serialization or the write failed — the
  /// tree file is best-effort and must never fail a completed export.
  Future<String?> writeTree(BuildTree tree, String repertoireFilePath) async {
    try {
      final json = await serializeTreeInIsolate(tree);
      await _storage().writeFile(treePathFor(repertoireFilePath), json);
      return json;
    } catch (e) {
      log.w(
        'tree save failed for $repertoireFilePath',
        name: _logName,
        error: e,
      );
      return null;
    }
  }

  /// Write the in-progress [tree] compactly so the build can be resumed.
  ///
  /// The capture is synchronous (a consistent snapshot of the live tree) and
  /// the encode runs off the UI isolate: this is called from pause and
  /// cancel, exactly when a multi-second freeze would be felt. Best-effort.
  Future<void> writePartialTree(
    BuildTree tree,
    String repertoireFilePath,
  ) async {
    try {
      final json = await serializeTreeInIsolate(tree, indent: false);
      await _storage().writeFile(partialTreePathFor(repertoireFilePath), json);
    } catch (e) {
      log.w(
        'partial tree save failed for $repertoireFilePath',
        name: _logName,
        error: e,
      );
    }
  }

  /// Remove the resumable partial tree, if any. Best-effort.
  Future<void> deletePartialTree(String repertoireFilePath) async {
    try {
      await _storage().deleteFile(partialTreePathFor(repertoireFilePath));
    } catch (e) {
      log.w(
        'partial tree delete failed for $repertoireFilePath',
        name: _logName,
        error: e,
      );
    }
  }

  /// Read the expectimax database saved beside [repertoireFilePath]: the
  /// last full build's tree and every probe since. Either may be absent. A
  /// read or decode failure is logged independently, so a corrupt file
  /// cannot hide the other file's valid analysis.
  Future<SavedExpectimaxDatabase> readDatabase(
    String repertoireFilePath,
  ) async {
    final storage = _storage();
    BuildTree? tree;
    var probes = <BuildTree>[];
    try {
      final treeJson = await _readIfPresent(
        storage,
        treePathFor(repertoireFilePath),
      );
      if (treeJson != null) {
        tree = await Isolate.run(() => deserializeTree(treeJson));
      }
    } catch (e) {
      log.w(
        'tree load failed for $repertoireFilePath',
        name: _logName,
        error: e,
      );
    }
    try {
      final probesJson = await _readIfPresent(
        storage,
        probesPathFor(repertoireFilePath),
      );
      if (probesJson != null) {
        probes = await Isolate.run(
          () => ExpectimaxProbeStore.decode(probesJson),
        );
      }
    } catch (e) {
      log.w(
        'probe load failed for $repertoireFilePath',
        name: _logName,
        error: e,
      );
    }
    return (tree: tree, probes: probes);
  }

  /// Write the expectimax database: [probeTrees] to the probe file (which
  /// is removed when there are none), and [mainTree] to the tree file when
  /// given. Rethrows after logging — a caller that reports "saved" must
  /// only do so when the write succeeded.
  Future<void> writeDatabase(
    String repertoireFilePath, {
    required List<BuildTree> probeTrees,
    BuildTree? mainTree,
  }) async {
    final storage = _storage();
    try {
      final probesPath = probesPathFor(repertoireFilePath);
      if (probeTrees.isEmpty) {
        if (await storage.fileExists(probesPath)) {
          await storage.deleteFile(probesPath);
        }
      } else {
        final json = await Isolate.run(
          () => ExpectimaxProbeStore.encode(probeTrees),
        );
        await storage.writeFile(probesPath, json);
      }
      if (mainTree != null) {
        final json = await serializeTreeInIsolate(mainTree);
        await storage.writeFile(treePathFor(repertoireFilePath), json);
      }
    } catch (e) {
      log.w(
        'expectimax database save failed for $repertoireFilePath',
        name: _logName,
        error: e,
      );
      rethrow;
    }
  }

  /// Write the trap index. Always written, even when empty, so the UI can
  /// tell "never generated" from "no traps found". Best-effort: a failure
  /// costs the trap list, not the build — logged because a finished
  /// repertoire with no traps is otherwise indistinguishable from a
  /// position that genuinely has none.
  Future<void> writeTrapIndex(
    List<TrapLineInfo> traps,
    String repertoireFilePath,
  ) async {
    try {
      await TrapExtractor.saveToFile(traps, repertoireFilePath);
    } catch (e) {
      log.w(
        'trap index save failed for $repertoireFilePath',
        name: _logName,
        error: e,
      );
    }
  }

  /// Write the course's model games again as a companion game collection —
  /// real headers, real results, the same annotations — so the PGN viewer
  /// opens them as games rather than study chapters. A course with no model
  /// games removes a stale companion from an earlier run so the two never
  /// disagree. Returns the path written, or null when nothing was (no games,
  /// or a failure, which is logged and not fatal).
  Future<String?> writeModelGames(
    ComposedCourse course,
    String repertoireFilePath,
  ) async {
    final path = modelGamesPathFor(repertoireFilePath);
    try {
      if (course.modelGamePgns.isEmpty) {
        await _storage().deleteFile(path);
        return null;
      }
      await _storage().writeFile(path, course.modelGamesPgn());
      return path;
    } catch (e) {
      log.w('model games file not written: $path', name: _logName, error: e);
      return null;
    }
  }

  static Future<String?> _readIfPresent(
    StorageService storage,
    String path,
  ) async {
    if (!await storage.fileExists(path)) return null;
    final text = await storage.readFile(path);
    return text == null || text.isEmpty ? null : text;
  }
}
