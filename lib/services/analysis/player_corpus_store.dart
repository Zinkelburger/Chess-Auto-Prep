import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../models/analysis_player_info.dart';
import '../../utils/atomic_file.dart';
import '../../utils/file_operation_lock.dart';
import '../game_store/game_store.dart';
import '../game_store/game_store_service.dart';
import '../../chess_core/pgn/pgn_text.dart';
import '../storage/app_paths.dart';

/// One published generation of a player's downloaded games.
class PlayerCorpus {
  const PlayerCorpus(
    this.info,
    this.directory,
    this.revision,
    this.fingerprint,
  );
  final AnalysisPlayerInfo info;

  /// The player's directory under the analysis-games root.
  final Directory directory;

  /// `<microseconds>-<sha256>`; names the generation's folder on disk.
  final String revision;

  /// SHA-256 of the PGN text; keys derived caches.
  final String fingerprint;

  String get pgnPath =>
      p.join(directory.path, 'versions', revision, 'games.pgn');
  String cachePath(String name) => p.join(
    directory.path,
    'versions',
    revision,
    'derived',
    fingerprint,
    name,
  );
}

/// One player's published corpus is one atomic manifest pointing at a staged
/// generation. Old generations and legacy flat files are retained for recovery.
/// The SQLite collection is a rebuildable index, never a second source of truth.
class PlayerCorpusStore {
  PlayerCorpusStore({AtomicFileWriter? writer})
    : _writer = writer ?? AtomicFileWriter();
  final AtomicFileWriter _writer;

  static const _manifestName = 'current.json';
  static const _manifestVersion = 1;
  static final _revisionPattern = RegExp(r'^[0-9]+-[a-f0-9]{64}$');

  Future<Directory> _root() => AppPaths.analysisGamesDirectory(create: true);

  static File _manifestFile(Directory directory) =>
      File(p.join(directory.path, _manifestName));

  Future<T> _locked<T>(
    AnalysisPlayerInfo info,
    Future<T> Function(Directory) action,
  ) async {
    final root = await _root();
    return withFileOperationLock(
      p.join(root.path, '.transactions', info.playerKey),
      () => action(Directory(p.join(root.path, info.playerKey))),
    );
  }

  Future<PlayerCorpus?> load(
    String platform,
    String username, {
    bool reconcile = true,
  }) {
    final identity = AnalysisPlayerInfo(platform: platform, username: username);
    return _locked(identity, (directory) async {
      final corpus = await _readOrMigrate(identity, directory);
      if (corpus == null || !reconcile) return corpus;
      return _reconcile(corpus);
    });
  }

  Future<PlayerCorpus> save(AnalysisPlayerInfo info, String pgn) =>
      _locked(info, (directory) async {
        final corpus = await _publish(info, pgn, directory);
        return _reconcile(corpus);
      });

  /// The current manifest, or a corpus migrated from legacy flat files when
  /// no manifest (not even a tombstone) exists yet.
  Future<PlayerCorpus?> _readOrMigrate(
    AnalysisPlayerInfo identity,
    Directory directory,
  ) async {
    final corpus = await _read(directory);
    if (corpus != null || await _manifestFile(directory).exists()) {
      return corpus;
    }
    return _migrate(identity, directory);
  }

  Future<PlayerCorpus> _publish(
    AnalysisPlayerInfo info,
    String pgn,
    Directory directory,
  ) async {
    final fingerprint = _fingerprintOf(pgn);
    final revision = '${DateTime.now().microsecondsSinceEpoch}-$fingerprint';
    final corpus = PlayerCorpus(
      info.copyWith(gameCount: countPgnGames(pgn)),
      directory,
      revision,
      fingerprint,
    );
    await _writer.writeText(File(corpus.pgnPath), pgn, createOnly: true);
    // Each retained generation has its own metadata as well as its PGN.
    await _writer.writeText(
      File(p.join(directory.path, 'versions', revision, 'metadata.json')),
      _encodeManifest(corpus),
      createOnly: true,
    );
    await _writeManifest(corpus);
    return corpus;
  }

  static String _fingerprintOf(String pgn) =>
      sha256.convert(utf8.encode(pgn)).toString();

  static String _encodeManifest(PlayerCorpus corpus, {bool deleted = false}) =>
      jsonEncode({
        'version': _manifestVersion,
        'revision': corpus.revision,
        'fingerprint': corpus.fingerprint,
        'deleted': deleted,
        'player': corpus.info.toJson(),
      });

  Future<void> _writeManifest(PlayerCorpus corpus, {bool deleted = false}) =>
      _writer.writeText(
        _manifestFile(corpus.directory),
        _encodeManifest(corpus, deleted: deleted),
      );

  /// The published corpus, or null when there is no manifest or it is a
  /// tombstone. A manifest that names another player or a malformed
  /// revision is corruption and throws rather than being served.
  Future<PlayerCorpus?> _read(Directory directory) async {
    final raw = await readTextFileSafely(_manifestFile(directory));
    if (raw == null) return null;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data['deleted'] == true) return null;
    final revision = data['revision'] as String;
    if (!_revisionPattern.hasMatch(revision)) {
      throw const FormatException('Invalid player corpus revision');
    }
    final info = AnalysisPlayerInfo.fromJson(
      (data['player'] as Map).cast<String, dynamic>(),
    );
    if (p.basename(directory.path) != info.playerKey) {
      throw const FormatException(
        'Player identity does not match its directory',
      );
    }
    return PlayerCorpus(
      info,
      directory,
      revision,
      data['fingerprint'] as String,
    );
  }

  /// Publish the legacy flat `<key>.json` + `<key>.pgn` pairs for [identity]
  /// as one generation. The originals are never deleted.
  Future<PlayerCorpus?> _migrate(
    AnalysisPlayerInfo identity,
    Directory directory,
  ) async {
    final root = await _root();
    final parts = <String>[];
    AnalysisPlayerInfo? metadata;
    // Inspect identity fields, not filename suffixes: a legitimate name may
    // itself end in _white_analysis. Never delete an ambiguous legacy file.
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File || p.extension(entity.path) != '.json') continue;
      final data = await _legacyMetadataFor(identity, entity);
      if (data == null) continue;
      final raw = await readTextFileSafely(
        File(p.setExtension(entity.path, '.pgn')),
      );
      if (raw == null) continue;
      metadata ??= AnalysisPlayerInfo.fromJson(data);
      if (!parts.contains(raw)) parts.add(raw);
    }
    if (metadata == null) return null;
    return _publish(metadata, parts.join('\n\n'), directory);
  }

  /// The legacy metadata in [file] when it belongs to [identity]
  /// (case-insensitive username on the same platform), else null.
  static Future<Map<String, dynamic>?> _legacyMetadataFor(
    AnalysisPlayerInfo identity,
    File file,
  ) async {
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic>) return null;
      final username = value['username'];
      if (value['platform'] != identity.platform ||
          username is! String ||
          username.toLowerCase() != identity.username.toLowerCase()) {
        return null;
      }
      return value;
    } on FormatException {
      return null;
    }
  }

  Future<List<AnalysisPlayerInfo>> list() async {
    final root = await _root();
    final identities = <String, AnalysisPlayerInfo>{};
    await for (final entity in root.list(followLinks: false)) {
      final raw = await _identitySourceText(entity);
      if (raw == null) continue;
      final info = _identityFrom(raw);
      if (info != null) identities[info.playerKey] = info;
    }
    final result = <AnalysisPlayerInfo>[];
    for (final identity in identities.values) {
      final corpus = await load(identity.platform, identity.username);
      if (corpus != null) result.add(corpus.info);
    }
    result.sort(
      (a, b) => (b.downloadedAt ?? DateTime(1970)).compareTo(
        a.downloadedAt ?? DateTime(1970),
      ),
    );
    return result;
  }

  /// A player directory's manifest or a legacy flat metadata file.
  static Future<String?> _identitySourceText(FileSystemEntity entity) {
    if (entity is Directory && p.basename(entity.path).startsWith('player-')) {
      return readTextFileSafely(_manifestFile(entity));
    }
    if (entity is File && p.extension(entity.path) == '.json') {
      return readTextFileSafely(entity);
    }
    return Future.value();
  }

  /// The player identity in a manifest (`player` object) or a legacy flat
  /// metadata file (top-level fields); null when it is neither.
  static AnalysisPlayerInfo? _identityFrom(String raw) {
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return null;
      final value = data['player'] ?? data;
      if (value is! Map ||
          value['platform'] is! String ||
          value['username'] is! String) {
        return null;
      }
      return AnalysisPlayerInfo.fromJson(value.cast<String, dynamic>());
    } on FormatException {
      return null;
    }
  }

  Future<void> tombstone(String platform, String username) async {
    final identity = AnalysisPlayerInfo(platform: platform, username: username);
    await _locked(identity, (directory) async {
      final corpus = await _readOrMigrate(identity, directory);
      if (corpus == null) return;
      // A persistent tombstone prevents old flat backups being re-imported
      // after deletion. All PGN generations remain recoverable on disk.
      await _writeManifest(corpus, deleted: true);
      final store = await GameStoreService.instance.open();
      store.deleteCollection(GameCollections.analysis(identity.playerKey));
      store.deleteCollection(
        GameCollections.analysis(identity.legacyPlayerKey),
      );
    });
  }

  /// Re-derive the manifest from the PGN actually on disk (a user may have
  /// edited it) and bring the SQLite index up to date with it.
  Future<PlayerCorpus> _reconcile(PlayerCorpus corpus) async {
    return withTextFileSnapshot(File(corpus.pgnPath), (text) async {
      if (text == null) {
        throw StateError(
          'The published player PGN is missing; previous generations were retained.',
        );
      }
      final fingerprint = _fingerprintOf(text);
      final warning = await _reindex(corpus.info, text, fingerprint);
      final result = PlayerCorpus(
        corpus.info.copyWith(
          gameCount: countPgnGames(text),
          storageWarning: warning,
          clearStorageWarning: warning == null,
        ),
        corpus.directory,
        corpus.revision,
        fingerprint,
      );
      if (_encodeManifest(result) != _encodeManifest(corpus)) {
        await _writeManifest(result);
      }
      return result;
    });
  }

  /// Rebuild the position-search index when its fingerprint no longer matches
  /// the PGN. Returns a storage warning when the index is unavailable: the
  /// games themselves are safe on disk, so an index failure must not fail
  /// the load or save.
  static Future<String?> _reindex(
    AnalysisPlayerInfo info,
    String text,
    String fingerprint,
  ) async {
    final collection = GameCollections.analysis(info.playerKey);
    try {
      final store = await GameStoreService.instance.open();
      if (store.collectionFingerprint(collection) != fingerprint) {
        // Never serve the previous corpus as a current search result while
        // the new index is pending. The PGN remains fully available.
        store.deleteCollection(collection);
        await GameStoreService.instance.importPgnInBackground(
          collection: collection,
          pgnText: text,
          replace: true,
        );
        store.setCollectionFingerprint(collection, fingerprint);
        store.deleteCollection(GameCollections.analysis(info.legacyPlayerKey));
      }
      return null;
    } catch (_) {
      // Any SQLite failure (locked, missing, corrupt) degrades to a warning;
      // the next open retries the import.
      return 'Games are saved. Position search is unavailable and will retry when opened.';
    }
  }
}
