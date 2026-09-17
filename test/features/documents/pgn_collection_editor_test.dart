import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/documents/controllers/pgn_collection_editor.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_repository.dart';
import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import '../../support/scripted_document_store.dart';

class Repository implements PgnCollectionRepository {
  final writes = <Map<String, String>>[];
  final recoveries = <String>[];
  Future<PgnWriteResult> Function()? outcome;
  @override
  Future<PgnWriteResult> patch(String path, Map<String, String> edits) async {
    writes.add(Map.of(edits));
    return outcome != null
        ? outcome!()
        : PgnSaved(before: null, after: snapshot(edits.values.join('\n\n')));
  }

  @override
  Future<String?> retainRecovery(String content) async {
    recoveries.add(content);
    return '/recovery/${recoveries.length}.pgn';
  }

  @override
  Future<PgnOpenResult> open(String path) async =>
      PgnOpened(snapshot('opened', path: path));
  @override
  Future<PgnWriteResult> create(String path, String content) async =>
      PgnSaved(before: null, after: snapshot(content, path: path));
  @override
  Future<PgnWriteResult> save(PgnSnapshot baseline, String content) async =>
      PgnSaved(
        before: baseline,
        after: snapshot(content, path: baseline.path),
      );
  @override
  Future<DateTime?> modified(String path) async => DateTime(2026);
}

void main() {
  late Repository repository;
  late PgnCollectionEditor editor;
  late List<PgnGameEntry> games;
  var savedCallbacks = 0;
  PgnGameEntry game(String name) => PgnGameEntry(
    headers: {'Event': name},
    pgnText: '[Event "$name"]\n\n1. e4 *',
  );
  setUp(() {
    games = [game('First')];
    repository = Repository();
    savedCallbacks = 0;
    editor = PgnCollectionEditor(
      repository: repository,
      path: () => '/games.pgn',
      games: () => games,
      collectionPreamble: () => '; Retain this banner',
      selectedGame: () => games.first,
      onContentChanged: ({required resetIndex}) {},
      onSaved: (_) => savedCallbacks++,
      onSavedCopy: (_) {},
      isActive: () => true,
    );
    editor.adoptPersistedGames(games);
    editor.setAutoSave(false);
  });
  tearDown(() => editor.dispose());

  test(
    'perspective saves only the changed first game through its baseline',
    () async {
      games.add(game('Second'));
      editor.adoptPersistedGames(games);
      final original = games.first.pgnText;
      final other = games.last.pgnText;
      await editor.setPerspectiveHeader('black');
      expect(editor.hasUnsavedChanges, isTrue);
      expect(repository.writes, isEmpty);
      expect(await editor.saveChanges(), isTrue);
      expect(repository.writes.single.keys.single, original);
      expect(
        repository.writes.single.values.single,
        contains('[StudyPerspective "black"]'),
      );
      expect(games.last.pgnText, other);
      expect(editor.hasUnsavedChanges, isFalse);
    },
  );

  test(
    'perspective conflicts retain the new view without replacing the source',
    () async {
      repository.outcome = () async => const PgnConflict(null);
      await editor.setPerspectiveHeader('black');
      expect(await editor.saveChanges(), isFalse);
      expect(editor.hasUnsavedChanges, isTrue);
      expect(
        repository.recoveries.single,
        contains('[StudyPerspective "black"]'),
      );
      expect(editor.canReplaceCollection(), isFalse);
    },
  );

  test(
    'perspective saves while solitaire annotations stay screen-only',
    () async {
      final original = games.first.pgnText;
      editor.persistMoveCommentsFor(
        games.first,
        '1. e4 {revealed in drill} *',
        writeToFile: false,
      );
      await editor.setPerspectiveHeader('black');
      expect(editor.hasUnsavedChanges, isTrue);
      expect(await editor.saveChanges(), isTrue);
      expect(repository.writes.single.keys.single, original);
      expect(
        repository.writes.single.values.single,
        contains('[StudyPerspective "black"]'),
      );
      expect(
        repository.writes.single.values.single,
        isNot(contains('revealed in drill')),
      );
      expect(games.first.pgnText, contains('revealed in drill'));
    },
  );

  test(
    'a submitted receipt leaves later edits dirty and next save uses it',
    () async {
      final gate = Completer<PgnWriteResult>();
      repository.outcome = () => gate.future;
      editor.persistMoveCommentsFor(games.first, '1. e4 {first} *');
      final first = editor.saveChanges();
      await Future<void>.delayed(Duration.zero);
      editor.persistMoveCommentsFor(games.first, '1. e4 {later} *');
      gate.complete(
        PgnSaved(
          before: null,
          after: snapshot(repository.writes.single.values.single),
        ),
      );
      expect(await first, isFalse);
      expect(editor.hasUnsavedChanges, isTrue);
      repository.outcome = null;
      expect(await editor.saveChanges(), isTrue);
      expect(repository.writes.last.keys.single, contains('{first}'));
      expect(repository.writes.last.values.single, contains('{later}'));
    },
  );

  test(
    'failed first write blocks queued retries and retains every submitted draft',
    () async {
      final gate = Completer<PgnWriteResult>();
      repository.outcome = () => gate.future;
      editor.persistMoveCommentsFor(games.first, '1. e4 {first} *');
      final first = editor.saveChanges();
      await Future<void>.delayed(Duration.zero);
      editor.persistMoveCommentsFor(games.first, '1. e4 {latest} *');
      final queued = editor.doPersistMetadata();
      gate.complete(const PgnConflict(null));
      await first;
      await queued;
      expect(repository.writes, hasLength(1));
      expect(repository.recoveries, hasLength(2));
      expect(repository.recoveries.last, contains('{latest}'));
      expect(repository.recoveries.last, startsWith('; Retain this banner'));
      editor.setAutoSave(true);
      await editor.flushPendingMetadata();
      expect(repository.writes, hasLength(1));
      expect(editor.canReplaceCollection(), isFalse);
      repository.outcome = null;
      expect(await editor.saveChanges(), isTrue);
    },
  );

  test('uncertain writes cannot be replayed by explicit Save', () async {
    repository.outcome = () async => PgnWriteUncertain(
      error: StateError('ack lost'),
      before: null,
      observed: null,
    );
    editor.setRating(4);
    expect(await editor.saveChanges(), isFalse);
    expect(await editor.saveChanges(), isFalse);
    expect(repository.writes, hasLength(1));
    expect(editor.lastResult, isA<PgnWriteUncertain>());
    expect(editor.errorMessage, contains('Review the file'));
  });

  test(
    'outgoing failed work cannot block or stamp a replacement collection',
    () async {
      final gate = Completer<PgnWriteResult>();
      repository.outcome = () => gate.future;
      editor.setRating(4);
      final first = editor.saveChanges();
      await Future<void>.delayed(Duration.zero);
      games = [game('Second')];
      editor.adoptPersistedGames(games);
      editor.clearEditedGames();
      editor.clearScreenOnlyMovetext();
      gate.complete(const PgnConflict(null));
      expect(await first, isFalse);
      expect(editor.lastResult, isNull);
      expect(savedCallbacks, 0);
      repository.outcome = null;
      editor.setRating(2);
      expect(await editor.saveChanges(), isTrue);
      expect(savedCallbacks, 1);
    },
  );
}
