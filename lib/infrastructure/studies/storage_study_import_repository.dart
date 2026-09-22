import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../features/documents/models/pgn_document.dart';
import '../../features/documents/repositories/pgn_document_store.dart';
import '../../features/studies/models/import_source.dart';
import '../../features/studies/models/study_import_state.dart';
import '../../features/studies/repositories/study_import_repository.dart';
import '../../features/studies/repositories/study_library_repository.dart';
import '../../services/storage/study_naming.dart';
import '../../services/lichess_api_client.dart';
import '../../utils/atomic_file.dart';
import 'chessgames_collection_client.dart';
import 'lichess_study_client.dart' as lichess;

class StorageStudyImportRepository implements StudyImportRepository {
  StorageStudyImportRepository({
    required this.library,
    required this.documents,
    required this.cacheDirectory,
    required this.authHeaders,
    http.Client Function()? createClient,
  }) : _createClient = createClient ?? http.Client.new;

  final StudyLibraryRepository library;
  final PgnDocumentStore documents;
  final Future<Directory> Function() cacheDirectory;
  final Future<Map<String, String>> Function() authHeaders;
  final http.Client Function() _createClient;

  @override
  StudyImportSource openSource() => _Source(_createClient(), authHeaders);

  Future<File> _cache(String id) async {
    if (!RegExp(r'^\d+$').hasMatch(id)) throw ArgumentError.value(id, 'id');
    return File(p.join((await cacheDirectory()).path, '$id.pgn'));
  }

  @override
  Future<String?> readCachedGame(String id) async {
    try {
      final text = await (await _cache(id)).readAsString();
      return text.trim().isEmpty ? null : text;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> cacheGame(String id, String pgn) async {
    final file = await _cache(id);
    await file.parent.create(recursive: true);
    await writeTextFileAtomically(file, pgn);
  }

  @override
  Future<StudyImportPublication> publish(String name, String pgn) async {
    final base = sanitizeStudyName(name);
    for (var suffix = 1; suffix <= 100; suffix++) {
      String path;
      try {
        path = await library.pathForName(
          suffix == 1 ? base : '$base ($suffix)',
        );
      } catch (error) {
        return StudyImportPublication(
          path: '',
          content: pgn,
          outcome: PgnWriteFailed(error),
          failure: StudyImportFailure.publication,
        );
      }
      PgnWriteResult result;
      try {
        result = await documents.create(path, pgn);
      } catch (error) {
        result = PgnWriteUncertain(error: error, before: null, observed: null);
      }
      if (result is! PgnNameCollision || suffix == 100) {
        return StudyImportPublication(
          path: path,
          content: pgn,
          outcome: result,
          failure: result is PgnNameCollision
              ? StudyImportFailure.nameCollisions
              : null,
        );
      }
    }
    throw StateError('Unreachable publication attempt');
  }
}

class _Source implements StudyImportSource {
  _Source(this.client, this.authHeaders);
  final http.Client client;
  final Future<Map<String, String>> Function() authHeaders;
  bool _closed = false;
  final _closing = Completer<void>();
  Future<T> _whileOpen<T>(Future<T> operation) => Future.any([
    operation,
    _closing.future.then<T>(
      (_) => throw StateError('Study import source is closed'),
    ),
  ]);
  LichessApiClient? _lichess;
  void _checkOpen() {
    if (_closed) throw StateError('Study import source is closed');
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _closing.complete();
    final lichess = _lichess;
    if (lichess == null) {
      client.close();
    } else {
      lichess.close();
    }
  }

  @override
  Future<StudyGameFetch> fetchGame(String id) async {
    _checkOpen();
    final result = await _whileOpen(fetchGamePgn(id, client: client));
    _checkOpen();
    return (
      status: StudyGameFetchStatus.values.byName(result.status.name),
      pgn: result.pgn,
    );
  }

  @override
  Future<StudyCollectionSource> fetchCollection(String id) async {
    _checkOpen();
    final html = await _whileOpen(fetchCollectionHtml(id, client: client));
    _checkOpen();
    return (
      gameIds: List<String>.unmodifiable(
        html == null ? <String>[] : extractCollectionGameIds(html),
      ),
      name:
          (html == null ? null : extractCollectionTitle(html)) ??
          'Collection $id',
    );
  }

  @override
  Future<FetchedStudy> fetchLichess(ImportSource source) async {
    _checkOpen();
    final headers = await _whileOpen(authHeaders());
    _checkOpen();
    final authorization = headers['Authorization'];
    final api = _lichess ??= LichessApiClient.withToken(
      authorization?.replaceFirst(
        RegExp(r'^Bearer ', caseSensitive: false),
        '',
      ),
      client: client,
    );
    final result = await lichess.fetchLichessStudy(
      source,
      loggedIn: authorization != null,
      get: (uri) async {
        _checkOpen();
        final response = await _whileOpen(
          api.get(uri, extraHeaders: {'Accept': 'application/x-chess-pgn'}),
        );
        _checkOpen();
        return response;
      },
    );
    _checkOpen();
    return result;
  }
}
