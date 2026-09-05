import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../models/analysis_player_info.dart';
import '../../utils/atomic_file.dart';
import '../../utils/file_operation_lock.dart';
import '../game_store/game_store.dart';
import '../game_store/game_store_service.dart';
import '../pgn_parsing_service.dart';
import '../storage/app_paths.dart';

class PlayerCorpus {
  PlayerCorpus(this.info, this.directory, this.revision, this.fingerprint);
  final AnalysisPlayerInfo info;
  final Directory directory;
  final String revision;
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
  Future<Directory> _root() => AppPaths.analysisGamesDirectory(create: true);

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
      var corpus = await _read(directory);
      if (corpus == null &&
          !await File(p.join(directory.path, 'current.json')).exists()) {
        corpus = await _migrate(identity, directory);
      }
      if (corpus != null && reconcile) corpus = await _reconcile(corpus);
      return corpus;
    });
  }

  Future<PlayerCorpus> save(AnalysisPlayerInfo info, String pgn) =>
      _locked(info, (directory) async {
        final corpus = await _publish(info, pgn, directory);
        return _reconcile(corpus);
      });

  Future<PlayerCorpus> _publish(
    AnalysisPlayerInfo info,
    String pgn,
    Directory directory,
  ) async {
    final fingerprint = sha256.convert(utf8.encode(pgn)).toString();
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
      jsonEncode(_manifest(corpus)),
      createOnly: true,
    );
    await _writer.writeText(
      File(p.join(directory.path, 'current.json')),
      jsonEncode(_manifest(corpus)),
    );
    return corpus;
  }

  Map<String, dynamic> _manifest(PlayerCorpus corpus, {bool deleted = false}) =>
      {
        'version': 1,
        'revision': corpus.revision,
        'fingerprint': corpus.fingerprint,
        'deleted': deleted,
        'player': corpus.info.toJson(),
      };

  Future<PlayerCorpus?> _read(Directory directory) async {
    final raw = await readTextFileSafely(
      File(p.join(directory.path, 'current.json')),
    );
    if (raw == null) return null;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data['deleted'] == true) return null;
    final revision = data['revision'] as String;
    if (!RegExp(r'^[0-9]+-[a-f0-9]{64}$').hasMatch(revision)) {
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
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      Map<String, dynamic> data;
      try {
        final value = jsonDecode(await entity.readAsString());
        if (value is! Map<String, dynamic> ||
            value['platform'] != identity.platform ||
            value['username'] is! String ||
            (value['username'] as String).toLowerCase() !=
                identity.username.toLowerCase()) {
          continue;
        }
        data = value;
      } on FormatException {
        continue;
      }
      final source = File(
        '${entity.path.substring(0, entity.path.length - 5)}.pgn',
      );
      final raw = await readTextFileSafely(source);
      if (raw == null) continue;
      metadata ??= AnalysisPlayerInfo.fromJson(data);
      if (!parts.contains(raw)) parts.add(raw);
    }
    if (metadata == null) return null;
    return _publish(metadata, parts.join('\n\n'), directory);
  }

  Future<List<AnalysisPlayerInfo>> list() async {
    final root = await _root();
    final identities = <String, AnalysisPlayerInfo>{};
    await for (final entity in root.list(followLinks: false)) {
      String? raw;
      if (entity is Directory &&
          p.basename(entity.path).startsWith('player-')) {
        raw = await readTextFileSafely(
          File(p.join(entity.path, 'current.json')),
        );
      } else if (entity is File && entity.path.endsWith('.json')) {
        raw = await readTextFileSafely(entity);
      }
      if (raw == null) continue;
      try {
        final data = jsonDecode(raw);
        if (data is! Map) continue;
        final value = data['player'] ?? data;
        if (value is! Map ||
            value['platform'] is! String ||
            value['username'] is! String) {
          continue;
        }
        final info = AnalysisPlayerInfo.fromJson(value.cast<String, dynamic>());
        identities[info.playerKey] = info;
      } on FormatException {
        continue;
      }
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

  Future<void> tombstone(String platform, String username) async {
    final identity = AnalysisPlayerInfo(platform: platform, username: username);
    await _locked(identity, (directory) async {
      var corpus = await _read(directory);
      if (corpus == null &&
          !await File(p.join(directory.path, 'current.json')).exists()) {
        corpus = await _migrate(identity, directory);
      }
      if (corpus == null) return;
      // A persistent tombstone prevents old flat backups being re-imported
      // after deletion. All PGN generations remain recoverable on disk.
      await _writer.writeText(
        File(p.join(directory.path, 'current.json')),
        jsonEncode(_manifest(corpus, deleted: true)),
      );
      final store = await GameStoreService.instance.open();
      store.deleteCollection(GameCollections.analysis(identity.playerKey));
      store.deleteCollection(
        GameCollections.analysis(identity.legacyPlayerKey),
      );
    });
  }

  Future<PlayerCorpus> _reconcile(PlayerCorpus corpus) async {
    return withTextFileSnapshot(File(corpus.pgnPath), (text) async {
      if (text == null) {
        throw StateError(
          'The published player PGN is missing; previous generations were retained.',
        );
      }
      final fingerprint = sha256.convert(utf8.encode(text)).toString();
      final collection = GameCollections.analysis(corpus.info.playerKey);
      String? warning;
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
          store.deleteCollection(
            GameCollections.analysis(corpus.info.legacyPlayerKey),
          );
        }
      } catch (_) {
        warning =
            'Games are saved. Position search is unavailable and will retry when opened.';
      }
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
      if (jsonEncode(_manifest(result)) != jsonEncode(_manifest(corpus))) {
        await _writer.writeText(
          File(p.join(corpus.directory.path, 'current.json')),
          jsonEncode(_manifest(result)),
        );
      }
      return result;
    });
  }
}
