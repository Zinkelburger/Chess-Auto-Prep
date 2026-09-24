import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../features/repertoires/models/repertoire_metadata.dart';
import '../../infrastructure/generation/storage_generation_draft_repository.dart';
import '../../features/repertoires/models/repertoire_creation.dart';
import '../../infrastructure/repertoires/native_repertoire_publication_store.dart';
import '../../infrastructure/repertoires/repertoire_import_planner.dart';
import '../../features/repertoires/models/repertoire_recovery_entry.dart';
import '../../features/settings/repositories/app_settings_repository.dart';
import '../../infrastructure/settings/shared_preferences_app_settings_repository.dart';
import '../../infrastructure/repertoires/repertoire_directory_mutations.dart';
import '../../infrastructure/repertoires/repertoire_reference_migration.dart';
import '../../models/tactics_set_metadata.dart';
import '../../utils/atomic_file.dart';
import '../../utils/file_text_reader.dart';
import '../../utils/log.dart';
import '../../utils/safe_file_name.dart';
import '../game_store/game_store.dart';
import '../game_store/game_store_service.dart';
import '../../infrastructure/training/move_attempt_store.dart';
import 'app_paths.dart';
import 'file_mutation_service.dart';
import 'pgn_game_count_cache.dart';
import 'storage_service.dart';

StorageService getStorageService() => IOStorageService(
  repertoireBooks:
      SharedPreferencesAppSettingsRepository.instance.repertoireBooks,
);

class IOStorageService implements StorageService {
  IOStorageService({
    Directory? documentsRoot,
    Directory? supportRoot,
    Directory? repertoiresRoot,
    this.repertoireBooks,
    this.repertoireMoveHook,
    this.repertoirePublicationHook,
  }) : _documentsRootOverride = documentsRoot,
       _supportRootOverride = supportRoot,
       _repertoiresRootOverride = repertoiresRoot;

  final Future<void> Function(RepertoirePublicationStep)?
  repertoirePublicationHook;
  Future<NativeRepertoirePublicationStore>? _publicationStore;
  Future<NativeRepertoirePublicationStore> _publications() async {
    final result = _publicationStore ??= _createPublications();
    try {
      return await result;
    } catch (_) {
      if (identical(result, _publicationStore)) _publicationStore = null;
      rethrow;
    }
  }

  Future<NativeRepertoirePublicationStore> _createPublications() async =>
      NativeRepertoirePublicationStore(
        root: await _repertoiresRoot(),
        guardCommit: _guardLibrary,
        testHook: repertoirePublicationHook,
      );
  Future<T> _guardLibrary<T>(Future<T> Function() action) async =>
      Platform.isLinux ? (await _moves()).guard(action) : action();

  Future<RepertoireCreationResult> publishRepertoire(
    CreateRepertoire request, {
    DateTime? createdAt,
    Future<void> Function(String path, String content)? createDocument,
  }) async {
    if (!Platform.isLinux) {
      throw UnsupportedError(
        'Native repertoire publication is not verified on this host',
      );
    }
    final now = createdAt ?? DateTime.now();
    final plan = await prepareRepertoireImport(request, now);
    return (await _publications()).publish(
      plan,
      createDocument: createDocument,
    );
  }

  final RepertoireBooksRepository? repertoireBooks;
  final Future<void> Function(RepertoireMoveStep)? repertoireMoveHook;
  Future<RepertoireDirectoryMutations>? _directoryMutations;

  Future<RepertoireDirectoryMutations> _moves() async {
    final result = _directoryMutations ??= _createMoves();
    try {
      return await result;
    } catch (_) {
      if (identical(_directoryMutations, result)) _directoryMutations = null;
      rethrow;
    }
  }

  Future<RepertoireDirectoryMutations> _createMoves() async =>
      RepertoireDirectoryMutations(
        root: await _repertoiresRoot(),
        trash: await _trashDirectory('repertoires'),
        trashAllowedRoot: await _documentsRoot(),
        journals: Directory(
          p.join((await _supportRoot()).path, 'repertoire-mutations'),
        ),
        repoint: RepertoireReferenceMigration(
          await _documentsRoot(),
          books: repertoireBooks,
        ).repoint,
        testHook: repertoireMoveHook,
        foreignRecoveryNotes: Directory(
          p.join((await _supportRoot()).path, 'unfinished-moves'),
        ),
        recoverAdditional: () async => (await _publications()).recover(),
      );

  /// Shared by document access and training files. The domain remains held
  /// through the complete operation, so reads cannot see a partially moved set.
  Future<T> guardDocumentOperation<T>(
    String path,
    Future<T> Function() action,
  ) async {
    if (Platform.isLinux && await _needsRecoveryGuard(path)) {
      return (await _moves()).guard(action);
    }
    return action();
  }

  Future<bool> _needsRecoveryGuard(String path) async {
    // v2 relocation notes can name studies and tactics as well as repertoires.
    // Conservatively guard all supported file operations inside Documents;
    // unrelated external files and Support bookkeeping keep their own scopes.
    final roots = [
      await _documentsRoot(),
      await _repertoiresRoot(create: false),
    ];
    for (final root in roots) {
      if (_contains(root.path, path)) return true;
    }
    // An external spelling can reach managed data through any existing
    // ancestor, including when create's final directories do not exist yet.
    // Keep the raw spelling too: `alias/..` follows the link's physical parent
    // in generic IO, while the native document adapter normalizes it first.
    final absolute = p.absolute(path);
    final normalized = p.normalize(absolute);
    final candidates = {
      await _recoveryMembershipPath(absolute),
      if (normalized != absolute) await _recoveryMembershipPath(normalized),
    };
    for (final root in roots) {
      final canonical = await _recoveryMembershipPath(p.absolute(root.path));
      if (candidates.any((candidate) => _contains(canonical, candidate))) {
        return true;
      }
    }
    return false;
  }

  /// Resolve the closest existing ancestor, retaining the missing suffix.
  /// This is only used by the Linux guard. ENOENT permits walking upwards;
  /// denied access, dangling links and other failures cannot prove that a
  /// candidate is unrelated, so they stop the operation before its action.
  static Future<String> _recoveryMembershipPath(String path) async {
    var ancestor = path;
    final missing = <String>[];
    while (true) {
      try {
        final resolved = await File(ancestor).resolveSymbolicLinks();
        return p.normalize(p.joinAll([resolved, ...missing.reversed]));
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode != 2 ||
            await FileSystemEntity.type(ancestor, followLinks: false) !=
                FileSystemEntityType.notFound) {
          rethrow;
        }
        final parent = p.dirname(ancestor);
        if (parent == ancestor) rethrow;
        missing.add(p.basename(ancestor));
        ancestor = parent;
      }
    }
  }

  static bool _contains(String root, String path) {
    final base = p.normalize(p.absolute(root));
    final candidate = p.normalize(p.absolute(path));
    return p.equals(base, candidate) || p.isWithin(base, candidate);
  }

  final Directory? _documentsRootOverride;
  final Directory? _supportRootOverride;
  final Directory? _repertoiresRootOverride;
  static const String _tacticsCsvFileName = 'tactics_positions.csv';
  static const String _analyzedGamesFileName = 'analyzed_games.txt';
  static const String _repertoireReviewsFileName = 'repertoire_reviews.csv';
  static const String _repertoireReviewHistoryFileName =
      'repertoire_review_history.csv';
  static const String _repertoireMoveProgressFileName =
      'repertoire_move_progress.csv';

  final PgnGameCountCache _gameCounts = PgnGameCountCache();
  final FileMutationService _mutations = FileMutationService.instance;

  Future<Directory> _documentsRoot() async =>
      _documentsRootOverride ?? await AppPaths.documentsDirectory();

  Future<Directory> _supportRoot() async =>
      _supportRootOverride ??
      _documentsRootOverride ??
      await AppPaths.supportDirectory();

  Future<Directory> _repertoiresRoot({bool create = true}) async {
    final root =
        _repertoiresRootOverride ??
        (_documentsRootOverride == null
            ? await AppPaths.repertoiresDirectory(create: create)
            : Directory(p.join(_documentsRootOverride.path, 'repertoires')));
    if (create && !await root.exists()) await root.create(recursive: true);
    return root;
  }

  Future<Directory> _documentsSubdirectory(String name) async {
    final directory = Directory(p.join((await _documentsRoot()).path, name));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> _studiesRoot() =>
      _documentsSubdirectory(AppPaths.studiesDirectoryName);

  Future<Directory> _tacticsSetsRoot() =>
      _documentsSubdirectory(AppPaths.tacticsSetsDirectoryName);

  Future<File> _getFile(String filename) async {
    return File(p.join((await _documentsRoot()).path, filename));
  }

  /// `.pgn` files directly inside [dir] (not recursive), in listing order.
  Future<List<File>> _pgnFiles(
    Directory dir, {
    bool Function(String path) accept = _isPgnFile,
  }) async => [
    await for (final entity in dir.list())
      if (entity is File && accept(entity.path)) entity,
  ];

  static bool _isPgnFile(String path) =>
      p.extension(path).toLowerCase() == '.pgn';

  /// A `.pgn` under the repertoires tree that is a real chapter (not the
  /// raw-games sidecar written by the build-from-games flow).
  static bool _isChapterFile(String path) =>
      _isPgnFile(path) &&
      !p.basenameWithoutExtension(path).endsWith('_raw_games');

  /// [RepertoireMetadata] for each of [files], game counts from the cache.
  Future<List<RepertoireMetadata>> _describeFiles(List<File> files) =>
      Future.wait(
        files.map((file) async {
          final stat = await file.stat();
          return RepertoireMetadata(
            filePath: file.path,
            name: p.basenameWithoutExtension(file.path),
            gameCount: await _gameCounts.countFor(file, stat),
            lastModified: stat.modified,
          );
        }),
      );

  /// [_describeFiles], sorted by name case-insensitively.
  Future<List<RepertoireMetadata>> _describeFilesByName(
    List<File> files,
  ) async => (await _describeFiles(files))..sort(_byName);

  static int _byName(RepertoireMetadata a, RepertoireMetadata b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  Future<File> _resolveFile(String path) async {
    if (p.isAbsolute(path)) return File(path);
    return File(p.join((await _documentsRoot()).path, path));
  }

  Future<Directory> _trashDirectory([String? category]) async {
    final docs = await _documentsRoot();
    final trashRoot = p.join(docs.path, '.chess_auto_prep_trash');
    return Directory(
      category == null ? trashRoot : p.join(trashRoot, category),
    );
  }

  bool _isInside(Directory root, String path) {
    final normalizedRoot = p.normalize(p.absolute(root.path));
    final normalizedPath = p.normalize(p.absolute(path));
    return p.isWithin(normalizedRoot, normalizedPath);
  }

  Future<Directory> _rootForMove(String oldPath, String newPath) async {
    final docs = await _documentsRoot();
    if (_isInside(docs, oldPath) && _isInside(docs, newPath)) return docs;
    final support = await _supportRoot();
    if (_isInside(support, oldPath) && _isInside(support, newPath)) {
      return support;
    }
    final oldParent = Directory(p.dirname(p.normalize(p.absolute(oldPath))));
    final newParent = p.normalize(p.absolute(p.dirname(newPath)));
    if (p.equals(oldParent.path, newParent)) return oldParent;
    throw const UnsafeFileMutation(
      'External files may only be renamed within their existing directory.',
    );
  }

  // ── Generic file I/O ─────────────────────────────────────────────────────

  @override
  Future<String?> readFile(String path) async {
    final file = await _resolveFile(path);
    return guardDocumentOperation(file.path, () => readTextFileSafely(file));
  }

  @override
  Future<String> updateFile(
    String path,
    FutureOr<String> Function(String?) update,
  ) async {
    final file = await _resolveFile(path);
    return guardDocumentOperation(
      file.path,
      () => updateTextFileAtomically(file, update),
    );
  }

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    final file = await _resolveFile(path);
    await guardDocumentOperation(
      file.path,
      () => writeTextFileAtomically(
        file,
        content,
        createOnly: createOnly,
        expectedContent: expectedContent,
      ),
    );
  }

  @override
  Future<bool> fileExists(String path) async {
    final file = await _resolveFile(path);
    return guardDocumentOperation(file.path, () => textFileExistsSafely(file));
  }

  @override
  Future<void> deleteFile(String path) async {
    final file = await _resolveFile(path);
    await guardDocumentOperation(file.path, () => _deleteResolvedFile(file));
  }

  /// The configured ownership root of a managed file, never a caller's folder.
  /// Reject aliases before callers capture the document for a destructive action.
  Future<({Directory root, String path})> managedFileLocation(
    String path,
  ) async {
    final candidate = p.normalize(p.absolute(path));
    for (final configured in [await _documentsRoot(), await _supportRoot()]) {
      if (!await configured.exists()) continue;
      final lexical = p.normalize(p.absolute(configured.path));
      final canonical = p.normalize(await configured.resolveSymbolicLinks());
      final spelling = p.isWithin(lexical, candidate) ? lexical : canonical;
      if (!p.isWithin(spelling, candidate)) continue;
      await _mutations.validateManagedFilePath(
        File(candidate),
        allowedRoot: Directory(spelling),
      );
      return (
        root: Directory(canonical),
        path: p.join(canonical, p.relative(candidate, from: spelling)),
      );
    }
    throw UnsafeFileMutation(
      'Refusing to remove $path: it is not managed app data.',
    );
  }

  Future<void> _deleteResolvedFile(File file) async {
    if (!await file.exists()) return;
    final docs = await _documentsRoot();
    if (_isInside(docs, file.path)) {
      await _mutations.quarantineFile(
        file,
        allowedRoot: docs,
        quarantineRoot: await _trashDirectory('files'),
      );
      return;
    }
    final support = await _supportRoot();
    if (_isInside(support, file.path)) {
      await _mutations.deleteDisposableFile(file, allowedRoot: support);
      return;
    }
    throw UnsafeFileMutation(
      'Refusing to delete ${file.path}: it is not managed app data.',
    );
  }

  @override
  Future<({int size, DateTime modified})?> fileStat(String path) async {
    final file = await _resolveFile(path);
    return guardDocumentOperation(file.path, () => _fileStat(file));
  }

  Future<({int size, DateTime modified})?> _fileStat(File file) async {
    try {
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      return (size: stat.size, modified: stat.modified);
    } catch (_) {
      // Unreadable is "absent" to callers that only want a freshness check.
      return null;
    }
  }

  @override
  Future<void> renameFile(String oldPath, String newPath) async {
    final source = await _resolveFile(oldPath);
    final destination = await _resolveFile(newPath);
    // Even an external PGN can have attempts in Documents. Its namespace
    // change and the managed reference rewrite share the recovery domain.
    await _guardLibrary(() => _renameResolvedFile(source, destination));
  }

  /// The caller already owns the domain, including for external paths. These
  /// helpers acquire only namespace/file locks, never the public storage guard.
  Future<void> _renameResolvedFile(File source, File destination) async {
    await _mutations.moveFileNoReplace(
      source,
      destination,
      allowedRoot: await _rootForMove(source.path, destination.path),
    );
    final attempts = await _getFile(MoveAttemptStore.fileName);
    if (await readTextFileSafely(attempts) == null) return;
    await updateTextFileAtomically(
      attempts,
      (raw) => MoveAttemptStore.repointText(
        raw,
        from: source.path,
        to: destination.path,
      ),
    );
  }

  @override
  String parentPath(String filePath) => p.dirname(filePath);

  // ── Repertoire file management ────────────────────────────────────────────

  @override
  Future<List<RepertoireMetadata>> listRepertoireFiles() async => _guardLibrary(
    () async => _describeFiles(
      await _pgnFiles(await _repertoiresRoot(), accept: _isChapterFile),
    ),
  );

  @override
  Future<String> repertoireFilePath(String name) async {
    final dir = await _repertoiresRoot();
    return p.join(dir.path, '${requireSafeFileName(name)}.pgn');
  }

  // ── Repertoire folders + chapters ─────────────────────────────────────────

  /// One-time fold of legacy flat `repertoires/<name>.pgn` files into
  /// `repertoires/<name>/Main.pgn` so every repertoire is a folder. Each move
  /// is best-effort and isolated: a failure or name collision leaves that file
  /// untouched rather than aborting the whole listing.
  Future<void> _migrateFlatRepertoires(Directory dir) async {
    await for (final entity in dir.list()) {
      if (entity is! File || !_isChapterFile(entity.path)) continue;
      try {
        final base = p.basenameWithoutExtension(entity.path);
        final targetDir = Directory(p.join(dir.path, base));
        if (await targetDir.exists()) continue;
        await targetDir.create();
        await entity.rename(p.join(targetDir.path, 'Main.pgn'));
      } catch (e) {
        log.e('Repertoire migration skipped ${entity.path}: $e');
      }
    }
  }

  @override
  Future<List<RepertoireMetadata>> listRepertoires() =>
      _guardLibrary(_listRepertoires);

  Future<List<RepertoireMetadata>> _listRepertoires() async {
    final dir = await _repertoiresRoot();
    await _migrateFlatRepertoires(dir);

    final folders = <Directory>[
      await for (final entity in dir.list())
        if (entity is Directory &&
            p.basename(entity.path) !=
                RepertoireDirectoryMutations.stagingName &&
            p.basename(entity.path) !=
                StorageGenerationDraftRepository.directoryName &&
            p.basename(entity.path) != '.cap-pgn-history')
          entity,
    ];

    return Future.wait(
      folders.map((folder) async {
        var chapterCount = 0;
        DateTime lastModified = (await folder.stat()).modified;
        await for (final entity in folder.list()) {
          if (entity is File && _isChapterFile(entity.path)) {
            chapterCount++;
            final modified = (await entity.stat()).modified;
            if (modified.isAfter(lastModified)) lastModified = modified;
          }
        }
        return RepertoireMetadata(
          filePath: folder.path,
          name: p.basename(folder.path),
          gameCount: chapterCount,
          lastModified: lastModified,
        );
      }),
    );
  }

  @override
  Future<List<RepertoireMetadata>> listChapters(
    String repertoireDirPath,
  ) async {
    return guardDocumentOperation(repertoireDirPath, () async {
      final dir = Directory(repertoireDirPath);
      if (!await dir.exists()) return [];
      return _describeFilesByName(await _pgnFiles(dir, accept: _isChapterFile));
    });
  }

  @override
  Future<String> repertoireDirectoryPath(String name) async {
    final dir = await _repertoiresRoot();
    return p.join(dir.path, requireSafeFileName(name));
  }

  @override
  String chapterFilePath(String repertoireDirPath, String chapterName) =>
      p.join(repertoireDirPath, '${requireSafeFileName(chapterName)}.pgn');

  @override
  Future<String> renameRepertoireDirectory(
    String oldDirPath,
    String newName,
  ) async {
    final safeName = requireSafeFileName(newName);
    final root = await _repertoiresRoot();
    final parent = p.dirname(oldDirPath);
    final newPath = p.join(parent, safeName);
    if (Platform.isLinux) {
      await (await _moves()).move(oldDirPath, newPath);
      return newPath;
    }
    await _mutations.moveDirectoryNoReplace(
      Directory(oldDirPath),
      Directory(newPath),
      allowedRoot: root,
    );
    await MoveAttemptStore(this).repoint(from: oldDirPath, to: newPath);
    return newPath;
  }

  Future<List<RepertoireRecoveryEntry>> listRepertoireRecovery() async =>
      Platform.isLinux ? (await _moves()).listRecovery() : [];

  Future<void> restoreRepertoire(String id, {String? name}) async {
    if (!Platform.isLinux) {
      throw UnsupportedError('Restore is not available on this platform yet');
    }
    await (await _moves()).restore(id, name: name);
  }

  @override
  Future<void> deleteRepertoireDirectory(String dirPath) async {
    if (Platform.isLinux) {
      await (await _moves()).delete(dirPath);
      return;
    }
    final root = await _repertoiresRoot();
    final documents = await _documentsRoot();
    final trash = await _trashDirectory('repertoires');
    await guardDocumentOperation(
      dirPath,
      () => _mutations.quarantineDirectory(
        Directory(dirPath),
        allowedRoot: root,
        quarantineRoot: trash,
        quarantineAllowedRoot: documents,
      ),
    );
  }

  @override
  Future<List<String>> listSubdirectories(String dirPath) =>
      guardDocumentOperation(dirPath, () => _listSubdirectories(dirPath));

  Future<List<String>> _listSubdirectories(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];
    final out = <String>[
      await for (final entity in dir.list())
        if (entity is Directory &&
            p.basename(entity.path) !=
                StorageGenerationDraftRepository.directoryName &&
            p.basename(entity.path) != '.cap-pgn-history')
          entity.path,
    ];
    out.sort(
      (a, b) =>
          p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()),
    );
    return out;
  }

  @override
  Future<void> createDirectory(String path) async {
    final root = await _repertoiresRoot();
    await guardDocumentOperation(
      path,
      () => _mutations.createDirectoryNoReplace(
        Directory(path),
        allowedRoot: root,
      ),
    );
  }

  @override
  Future<void> moveDirectory(String oldPath, String newPath) async {
    if (Platform.isLinux) {
      await (await _moves()).move(oldPath, newPath);
      return;
    }
    final root = await _repertoiresRoot();
    await _mutations.moveDirectoryNoReplace(
      Directory(oldPath),
      Directory(newPath),
      allowedRoot: root,
    );
    await MoveAttemptStore(this).repoint(from: oldPath, to: newPath);
  }

  // ── Study file management ────────────────────────────────────────────────

  @override
  Future<List<RepertoireMetadata>> listStudyFiles() => _guardLibrary(
    () async => _describeFilesByName(await _pgnFiles(await _studiesRoot())),
  );

  @override
  Future<String> studyFilePath(String name) async {
    final dir = await _studiesRoot();
    return p.join(dir.path, '${requireSafeFileName(name)}.pgn');
  }

  // ── Tactics set management ───────────────────────────────────────────────

  @override
  Future<List<TacticsSetMetadata>> listTacticsSets() =>
      _guardLibrary(_listTacticsSets);

  Future<List<TacticsSetMetadata>> _listTacticsSets() async {
    final sets = await _describeFilesByName(
      await _pgnFiles(await _tacticsSetsRoot()),
    );
    return [
      for (final set in sets)
        TacticsSetMetadata(
          filePath: set.filePath,
          name: set.name,
          positionCount: set.gameCount,
          lastModified: set.lastModified,
        ),
    ];
  }

  @override
  Future<String> tacticsSetPath(String name) async {
    final dir = await _tacticsSetsRoot();
    return p.join(dir.path, '${requireSafeFileName(name)}.pgn');
  }

  @override
  Future<void> deleteTacticsSet(String name) async {
    await deleteFile(await tacticsSetPath(name));
  }

  @override
  Future<List<({String name, String path})>> listLegacyTacticsCsvSets() =>
      _guardLibrary(_listLegacyTacticsCsvSets);

  Future<List<({String name, String path})>> _listLegacyTacticsCsvSets() async {
    final dir = await _tacticsSetsRoot();
    return [
      await for (final entity in dir.list())
        if (p.extension(entity.path).toLowerCase() == '.csv')
          (name: p.basenameWithoutExtension(entity.path), path: entity.path),
    ];
  }

  @override
  Future<bool> migrateLegacyTacticsCsv(String defaultSetName) =>
      _guardLibrary(() => _migrateLegacyTacticsCsv(defaultSetName));

  Future<bool> _migrateLegacyTacticsCsv(String defaultSetName) async {
    try {
      if ((await _listTacticsSets()).isNotEmpty) return false;
      if ((await _listLegacyTacticsCsvSets()).isNotEmpty) return false;

      final legacyFile = await _getFile(_tacticsCsvFileName);
      if (!await legacyFile.exists()) return false;

      final content = await readTextFile(legacyFile);
      if (content.trim().isEmpty) return false;

      // Land it as a .csv set; the database's CSV→PGN migration converts it.
      final dir = await _tacticsSetsRoot();
      await writeTextFileAtomically(
        File(p.join(dir.path, '$defaultSetName.csv')),
        content,
        createOnly: true,
      );
      // The original is retained: another process may still use the old layout.
      log.i('Migrated legacy tactics CSV into set "$defaultSetName"');
      return true;
    } catch (e) {
      log.e('Error migrating legacy tactics CSV: $e');
      rethrow;
    }
  }

  @override
  Future<String?> readTacticsCsv() => readFile(_tacticsCsvFileName);

  @override
  Future<void> saveTacticsCsv(String csvContent) =>
      writeFile(_tacticsCsvFileName, csvContent);

  @override
  Future<List<String>> readAnalyzedGameIds() async =>
      (await readFile(_analyzedGamesFileName) ?? '')
          .split('\n')
          .where((id) => id.trim().isNotEmpty)
          .toList();

  @override
  Future<void> saveAnalyzedGameIds(List<String> ids) =>
      writeFile(_analyzedGamesFileName, ids.join('\n'));

  /// The tactics archive lives in the games database now (collection
  /// `tactics`); these two keep the whole-archive-as-text contract for the
  /// callers that still want it.  Hot paths (lookup by GameId, counts,
  /// pruning, appends) go to [GameStore] directly.
  @override
  Future<String?> readImportedPgns() async {
    final store = await GameStoreService.instance.open();
    if (store.count(GameCollections.tactics) == 0) return null;
    return store.exportPgn(GameCollections.tactics);
  }

  /// Replace the archive with [pgnContent] (empty = clear).
  @override
  Future<void> saveImportedPgns(String pgnContent) async {
    final store = await GameStoreService.instance.open();
    store.importPgn(
      pgnContent,
      collection: GameCollections.tactics,
      replace: true,
    );
  }

  @override
  Future<String?> readRepertoirePgn(String filename) => readFile(filename);

  @override
  Future<void> saveRepertoirePgn(String filename, String content) =>
      writeFile(filename, content);

  @override
  Future<String?> readRepertoireReviewsCsv() =>
      readFile(_repertoireReviewsFileName);

  @override
  Future<void> saveRepertoireReviewsCsv(String csvContent) =>
      writeFile(_repertoireReviewsFileName, csvContent);

  @override
  Future<String?> readRepertoireReviewHistoryCsv() =>
      readFile(_repertoireReviewHistoryFileName);

  @override
  Future<void> saveRepertoireReviewHistoryCsv(String csvContent) =>
      writeFile(_repertoireReviewHistoryFileName, csvContent);

  @override
  Future<String?> readRepertoireMoveProgressCsv() =>
      readFile(_repertoireMoveProgressFileName);

  @override
  Future<void> saveRepertoireMoveProgressCsv(String csvContent) =>
      writeFile(_repertoireMoveProgressFileName, csvContent);
}
