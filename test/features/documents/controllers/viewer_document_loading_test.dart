import 'dart:async';

import 'package:chess_auto_prep/chess_core/pgn/pgn_collection.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_document_controller.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/models/viewer_collection_load.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_decoder.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_analysis_port.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_computation.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_position_index_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_opening_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_solitaire_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_library_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_filter.dart';
import 'package:chess_auto_prep/infrastructure/documents/shared_preferences_viewer_repository.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../support/fake_desktop_fullscreen_port.dart';

const text = '; Retain this banner\n\n[Event "Practice"]\n\n1. e4 e5 *';
const snapshot = PgnSnapshot(
  path: '/collection.pgn',
  content: text,
  revision: PgnRevision(
    documentId: 'doc',
    nativeIdentity: 'inode',
    sha256: 'hash',
  ),
);

class Repository implements PgnCollectionRepository {
  Future<PgnOpenResult> Function(String) read = (_) async =>
      const PgnOpened(snapshot);
  Future<DateTime?> Function(String) stat = (_) async => DateTime.utc(2026);
  int reads = 0;
  @override
  Future<PgnOpenResult> open(String path) {
    reads++;
    return read(path);
  }

  @override
  Future<DateTime?> modified(String path) => stat(path);
  // Unexpected mutation calls fail, rather than silently touching real data.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DecodedPgnCollection parse(String text) =>
    DecodedPgnCollection(parseMultiGamePgn(text), pgnCollectionPreamble(text));

class Decoder implements PgnCollectionDecoder {
  Future<DecodedPgnCollection> Function(String) run = (text) async =>
      parse(text);
  int calls = 0;
  @override
  Future<DecodedPgnCollection> decode(String content) {
    calls++;
    return run(content);
  }
}

class _UnusedPort {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected ${invocation.memberName}');
}

class _Openings extends _UnusedPort implements ViewerOpeningRepository {}

class _Solitaire extends _UnusedPort implements ViewerSolitaireRepository {}

class _Library extends _UnusedPort implements PgnLibraryRepository {}

class _Filter extends _UnusedPort implements PgnCollectionFilter {}

class _Analysis implements ViewerAnalysisPort {
  @override
  void cancel() {}
  @override
  void clearEvals() {}
  @override
  Future<bool> tryLoadFromPgn(String text) async => false;
  @override
  Future<void> fillMissingBestLines(
    String text, {
    required void Function(String) onAnnotatedMovetext,
  }) async {}
}

class _IndexWork implements ViewerComputation<Map<String, List<int>>> {
  @override
  Future<Map<String, List<int>>> get result async => const {};
  @override
  void cancel() {}
}

class _Index implements ViewerPositionIndexRepository {
  @override
  Future<Map<String, List<int>>?> load(
    String path,
    List<GameRecord> source,
  ) async => const {};
  @override
  ViewerComputation<Map<String, List<int>>> build(List<GameRecord> source) =>
      _IndexWork();
  @override
  Future<void> save(
    String path,
    List<GameRecord> source,
    Map<String, List<int>> index,
  ) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Repository repository;
  late Decoder decoder;
  late ViewerDocumentController owner;
  late bool active;
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'pgn_viewer.auto_detect_openings': false,
    });
    repository = Repository();
    decoder = Decoder();
    active = true;
    owner = ViewerDocumentController(
      collectionRepository: repository,
      collectionDecoder: decoder,
      positionIndex: _Index(),
      openings: _Openings(),
      solitaireRepository: _Solitaire(),
      library: _Library(),
      collectionFilter: _Filter(),
      preferences: SharedPreferencesViewerRepository(
        SharedPreferences.getInstance,
      ),
      window: FakeDesktopFullscreenPort(),
      pgnWidgetController: PgnViewerWidgetController(),
      analysisController: _Analysis(),
      isActive: () => active,
    );
    owner.setAutoDetectOpenings(false);
  });
  tearDown(() {
    if (!owner.isDisposed) owner.dispose();
  });

  test(
    'adopts observed snapshot, banner, metadata and fresh protected entries',
    () async {
      expect(await owner.loadFile(snapshot.path), isTrue);
      expect(owner.editor.state.baseline, same(snapshot));
      expect(owner.loadedFileModified, DateTime.utc(2026));
      expect(owner.collectionPreamble, '; Retain this banner');
      expect(owner.collection.games.single.headers['Event'], 'Practice');
      expect(() => owner.collection.games.clear(), throwsUnsupportedError);
      owner.collection.games.single.pgnText = 'edited';
      expect(snapshot.content, text);
      expect(await owner.loadFile(snapshot.path), isTrue);
      expect(owner.collection.games.single.pgnText, contains('1. e4 e5'));
    },
  );

  test(
    'distinguishes missing, unreadable, empty and comment-only input',
    () async {
      Future<void> failure(String message) async {
        expect(await owner.loadFile(snapshot.path), isFalse);
        expect(owner.errorMessage, message);
        expect(owner.isLoading, isFalse);
      }

      repository.read = (_) async => const PgnMissing();
      await failure('File not found: collection.pgn');
      repository.read = (_) async => PgnReadFailed(StateError('denied'));
      await failure('Could not read collection.pgn');
      repository.read = (_) async => throw StateError('disconnected');
      await failure('Could not read collection.pgn');
      expect(decoder.calls, 0);
      expect(await owner.loadPgnContent('  '), isFalse);
      expect(owner.errorMessage, 'Clipboard is empty — copy some PGN first');
      expect(decoder.calls, 0);
      expect(await owner.loadPgnContent('; only a note'), isFalse);
      expect(owner.errorMessage, 'No valid PGN games found in the pasted text');
      repository.read = (_) async => PgnOpened(
        PgnSnapshot(
          path: snapshot.path,
          content: ' ',
          revision: snapshot.revision,
        ),
      );
      await failure('File is empty: collection.pgn');
      repository.read = (_) async => PgnOpened(
        PgnSnapshot(
          path: snapshot.path,
          content: '; only a note',
          revision: snapshot.revision,
        ),
      );
      await failure('No valid PGN games in collection.pgn');
    },
  );

  test(
    'new text invalidates a pending file read and prevents its decoding',
    () async {
      final pending = Completer<PgnOpenResult>();
      repository.read = (_) => pending.future;
      final first = owner.loadFile('slow');
      expect(await owner.loadPgnContent(text), isTrue);
      final replacement = owner.collection.games;
      expect(owner.editor.state.baseline, isNull);
      pending.complete(const PgnOpened(snapshot));
      expect(await first, isFalse);
      expect(owner.collection.games, same(replacement));
      expect(owner.filePath, isNull);
      expect(decoder.calls, 1);
    },
  );

  test(
    'new failed request also invalidates a previous successful read',
    () async {
      final pending = Completer<PgnOpenResult>();
      repository.read = (_) => pending.future;
      final first = owner.loadFile('slow');
      expect(await owner.loadPgnContent(''), isFalse);
      final message = owner.errorMessage;
      pending.complete(const PgnOpened(snapshot));
      expect(await first, isFalse);
      expect(owner.errorMessage, message);
      expect(owner.collection.games, isEmpty);
      expect(decoder.calls, 0);
    },
  );

  test('late read errors cannot replace the current collection', () async {
    final pending = Completer<PgnOpenResult>();
    repository.read = (_) => pending.future;
    final first = owner.loadFile('slow');
    expect(await owner.loadPgnContent(text), isTrue);
    final replacement = owner.collection.games;
    pending.completeError(StateError('late failure'));
    expect(await first, isFalse);
    expect(owner.collection.games, same(replacement));
    expect(owner.errorMessage, isNull);
  });

  test(
    'repeated loads of one path reject the first decoder completion',
    () async {
      final started = Completer<void>();
      final pending = Completer<DecodedPgnCollection>();
      decoder.run = (_) {
        started.complete();
        return pending.future;
      };
      final first = owner.loadFile(snapshot.path);
      await started.future;
      decoder.run = (text) async => parse(text);
      expect(await owner.loadFile(snapshot.path), isTrue);
      final current = owner.collection.games;
      pending.complete(parse(text));
      expect(await first, isFalse);
      expect(owner.collection.games, same(current));
      expect(owner.editor.state.baseline, same(snapshot));
    },
  );

  test(
    'navigation and close invalidate pending metadata and decoder errors',
    () async {
      owner.adoptDecodedCollection(parse(text), title: 'Retained navigation');
      final restore = owner.captureNavigationContext();
      final started = Completer<void>();
      final pending = Completer<DateTime?>();
      repository.stat = (_) {
        started.complete();
        return pending.future;
      };
      final first = owner.loadFile(snapshot.path);
      await started.future;
      expect(await restore(), isTrue);
      final current = owner.collection.games;
      pending.complete(DateTime.utc(2026));
      expect(await first, isFalse);
      expect(owner.collection.games, same(current));
      expect(owner.collectionTitle, 'Retained navigation');
      final decoding = Completer<DecodedPgnCollection>();
      decoder.run = (_) => decoding.future;
      final second = owner.loadPgnContent(text);
      owner.closeFile();
      decoding.completeError(const FormatException('stale parse'));
      expect(await second, isFalse);
      expect(owner.collection.games, isEmpty);
      expect(owner.errorMessage, isNull);
      expect(owner.isLoading, isFalse);
    },
  );

  test(
    'decoder failure retains parse diagnosis and the next request succeeds',
    () async {
      decoder.run = (_) async => throw const FormatException('invalid');
      expect(await owner.loadPgnContent(text), isFalse);
      expect(owner.errorMessage, 'Could not parse the pasted PGN');
      expect(await owner.loadFile(snapshot.path), isFalse);
      expect(owner.errorMessage, 'Could not parse collection.pgn');
      decoder.run = (text) async => parse(text);
      expect(await owner.loadPgnContent(text), isTrue);
      expect(owner.errorMessage, isNull);
    },
  );

  test(
    'disposal rejects pending work and prevents new decoding or reads',
    () async {
      final pending = Completer<DecodedPgnCollection>();
      decoder.run = (_) => pending.future;
      final first = owner.loadPgnContent(text);
      owner.dispose();
      pending.complete(parse(text));
      expect(await first, isFalse);
      expect(await owner.loadFile(snapshot.path), isFalse);
      expect(await owner.loadPgnContent(text), isFalse);
      expect(repository.reads, 0);
      expect(decoder.calls, 1);
    },
  );

  test(
    'metadata failure is unreadable and cannot adopt decoded games',
    () async {
      repository.stat = (_) async => throw StateError('stat denied');
      expect(await owner.loadFile(snapshot.path), isFalse);
      expect(owner.errorMessage, 'Could not read collection.pgn');
      expect(owner.collection.games, isEmpty);
      expect(owner.isLoading, isFalse);
    },
  );

  test(
    'inactive owner rejects pending and new reads without publication',
    () async {
      final pending = Completer<PgnOpenResult>();
      repository.read = (_) => pending.future;
      final first = owner.loadFile(snapshot.path);
      active = false;
      pending.complete(const PgnOpened(snapshot));
      expect(await first, isFalse);
      expect(await owner.loadFile(snapshot.path), isFalse);
      expect(await owner.loadPgnContent(text), isFalse);
      expect(repository.reads, 1);
      expect(decoder.calls, 0);
      expect(owner.collection.games, isEmpty);
      expect(owner.errorMessage, isNull);
    },
  );

  for (final file in [true, false]) {
    test(
      'reentrant loading notification closes before ${file ? 'file' : 'text'} I/O',
      () async {
        owner.addListener(() {
          if (owner.isLoading) owner.closeFile();
        });
        expect(
          await (file
              ? owner.loadFile(snapshot.path)
              : owner.loadPgnContent(text)),
          isFalse,
        );
        expect(repository.reads, 0);
        expect(decoder.calls, 0);
        expect(owner.collection.games, isEmpty);
        expect(owner.isLoading, isFalse);
      },
    );
  }

  test(
    'failure notification can start a replacement without stale error publication',
    () async {
      Future<bool>? replacement;
      owner.addListener(() {
        if (owner.errorMessage != null && replacement == null) {
          replacement = owner.loadPgnContent(text);
        }
      });
      expect(await owner.loadPgnContent(''), isFalse);
      expect(await replacement!, isTrue);
      expect(owner.collection.games.single.headers['Event'], 'Practice');
      expect(owner.errorMessage, isNull);
      expect(owner.isLoading, isFalse);
    },
  );

  test(
    'editing during decoding still protects the original collection',
    () async {
      owner.adoptDecodedCollection(parse(text));
      owner.editor.setAutoSave(false);
      final pending = Completer<DecodedPgnCollection>();
      decoder.run = (_) => pending.future;
      final operation = owner.loadFile(snapshot.path);
      await Future<void>.delayed(Duration.zero);
      owner.editor.setRating(5);
      final current = owner.collection.games;
      pending.complete(parse('[Event "Replacement"]\n\n1. d4 *'));
      expect(await operation, isFalse);
      expect(owner.collection.games, same(current));
      expect(owner.editor.hasUnsavedChanges, isTrue);
      expect(owner.editor.errorMessage, contains('Unsaved changes'));
      expect(owner.isLoading, isFalse);
    },
  );
}
