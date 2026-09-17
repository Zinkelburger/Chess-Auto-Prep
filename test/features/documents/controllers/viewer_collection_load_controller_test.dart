import 'dart:async';

import 'package:chess_auto_prep/chess_core/pgn/pgn_collection.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_collection_load_controller.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/models/viewer_collection_load.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_decoder.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_repository.dart';
import 'package:flutter_test/flutter_test.dart';

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
  @override
  Future<PgnOpenResult> open(String path) => read(path);
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

void main() {
  late Repository repository;
  late Decoder decoder;
  late ViewerCollectionLoadController owner;
  setUp(() {
    repository = Repository();
    decoder = Decoder();
    owner = ViewerCollectionLoadController(
      repository: repository,
      decoder: decoder,
    );
  });

  test(
    'hands off the observed snapshot, banner, metadata and fresh entries',
    () async {
      final result =
          await owner.loadFile(snapshot.path) as ViewerCollectionLoaded;
      expect(result.snapshot, same(snapshot));
      expect(result.modified, DateTime.utc(2026));
      expect(result.document.preamble, '; Retain this banner');
      expect(result.document.games.single.headers['Event'], 'Practice');
      expect(() => result.document.games.clear(), throwsUnsupportedError);
      result.document.games.single.pgnText = 'edited';
      expect(snapshot.content, text);
      final again =
          await owner.loadFile(snapshot.path) as ViewerCollectionLoaded;
      expect(again.document.games.single.pgnText, contains('1. e4 e5'));
    },
  );

  test(
    'distinguishes missing, unreadable, empty and comment-only input',
    () async {
      Future<void> failure(ViewerCollectionLoadFailure expected) async {
        final result =
            await owner.loadFile(snapshot.path) as ViewerCollectionLoadFailed;
        expect(result.failure, expected);
      }

      repository.read = (_) async => const PgnMissing();
      await failure(ViewerCollectionLoadFailure.missing);
      repository.read = (_) async => PgnReadFailed(StateError('denied'));
      await failure(ViewerCollectionLoadFailure.unreadable);
      repository.read = (_) async => throw StateError('disconnected');
      await failure(ViewerCollectionLoadFailure.unreadable);
      expect(decoder.calls, 0);
      expect(
        (await owner.loadText('  ') as ViewerCollectionLoadFailed).failure,
        ViewerCollectionLoadFailure.empty,
      );
      expect(decoder.calls, 0);
      expect(
        (await owner.loadText('; only a note') as ViewerCollectionLoadFailed)
            .failure,
        ViewerCollectionLoadFailure.noGames,
      );
    },
  );

  test(
    'new text invalidates a pending file read and prevents its decoding',
    () async {
      final pending = Completer<PgnOpenResult>();
      repository.read = (_) => pending.future;
      final first = owner.loadFile('slow');
      final revision = owner.revision;
      final replacement = await owner.loadText(text) as ViewerCollectionLoaded;
      expect(replacement.snapshot, isNull);
      expect(owner.isCurrent(revision), isFalse);
      pending.complete(const PgnOpened(snapshot));
      expect(await first, isNull);
      expect(decoder.calls, 1);
    },
  );

  test(
    'new failed request also invalidates a previous successful read',
    () async {
      final pending = Completer<PgnOpenResult>();
      repository.read = (_) => pending.future;
      final first = owner.loadFile('slow');
      expect(await owner.loadText(''), isA<ViewerCollectionLoadFailed>());
      pending.complete(const PgnOpened(snapshot));
      expect(await first, isNull);
    },
  );

  test('late read errors cannot replace the current result', () async {
    final pending = Completer<PgnOpenResult>();
    repository.read = (_) => pending.future;
    final first = owner.loadFile('slow');
    await owner.loadText(text);
    pending.completeError(StateError('late failure'));
    expect(await first, isNull);
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
      expect(
        await owner.loadFile(snapshot.path),
        isA<ViewerCollectionLoaded>(),
      );
      pending.complete(parse(text));
      expect(await first, isNull);
    },
  );

  test(
    'navigation and close invalidate pending metadata and decoder errors',
    () async {
      final started = Completer<void>();
      final pending = Completer<DateTime?>();
      repository.stat = (_) {
        started.complete();
        return pending.future;
      };
      final first = owner.loadFile(snapshot.path);
      await started.future;
      owner.invalidate();
      pending.complete(DateTime.utc(2026));
      expect(await first, isNull);
      final decoding = Completer<DecodedPgnCollection>();
      decoder.run = (_) => decoding.future;
      final second = owner.loadText(text);
      owner.invalidate();
      decoding.completeError(const FormatException('stale parse'));
      expect(await second, isNull);
    },
  );

  test(
    'current decoder failure is typed and the next request can succeed',
    () async {
      decoder.run = (_) async => throw const FormatException('invalid');
      final failure = await owner.loadText(text) as ViewerCollectionLoadFailed;
      expect(failure.failure, ViewerCollectionLoadFailure.decoding);
      expect(failure.cause, isA<FormatException>());
      decoder.run = (text) async => parse(text);
      expect(await owner.loadText(text), isA<ViewerCollectionLoaded>());
    },
  );

  test(
    'disposal rejects pending work and prevents new decoding or reads',
    () async {
      final pending = Completer<DecodedPgnCollection>();
      decoder.run = (_) => pending.future;
      final first = owner.loadText(text);
      owner.dispose();
      pending.complete(parse(text));
      expect(await first, isNull);
      repository.read = (_) => throw StateError('must not read');
      expect(await owner.loadFile(snapshot.path), isNull);
      expect(await owner.loadText(text), isNull);
      expect(decoder.calls, 1);
    },
  );
}
