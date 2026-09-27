import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/settings/models/repertoire_books.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/repertoire_reference_migration.dart';
import 'package:chess_auto_prep/infrastructure/settings/shared_preferences_app_settings_repository.dart';
import 'package:chess_auto_prep/services/game_store/game_store.dart';
import 'package:chess_auto_prep/services/game_store/game_store_schema.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/utils/training_csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// A fixture preference adapter, deliberately containing only book references.
// This does not export the production preferences file, which contains secrets.
class _BooksFile implements RepertoireBooksPreferences {
  _BooksFile(this.file);
  final File file;

  @override
  Future<RepertoireBooks> read() async {
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return RepertoireBooks(
      white: (json['white'] as List).cast<String>(),
      black: (json['black'] as List).cast<String>(),
    );
  }

  @override
  Future<void> writeSide(BookSide side, List<String> paths) async {
    final current = await read();
    final next = current.withSide(side, paths);
    await file.writeAsString(
      jsonEncode({'white': next.white, 'black': next.black}),
      flush: true,
    );
  }
}

/// Only used after all fixture writers/connections close. Copying an active
/// profile this way is unsafe: SQLite and PGNs have no shared transaction.
Future<void> _copyStoppedProfile(Directory source, Directory target) async {
  await target.create(recursive: true);
  await for (final entry in source.list(recursive: true, followLinks: false)) {
    final path = p.join(target.path, p.relative(entry.path, from: source.path));
    if (entry is Directory) {
      await Directory(path).create(recursive: true);
    } else if (entry is File) {
      await File(path).parent.create(recursive: true);
      await entry.copy(path);
    } else {
      throw StateError('Restore fixture must not silently follow links');
    }
  }
}

const _sourceGame =
    '[Event "Restore fixture"]\n[GameId "source-1"]\n'
    '[White "A"]\n[Black "B"]\n[Result "*"]\n\n'
    '1. e4 e5 {source annotation} 2. Nf3 *';
const _chapter =
    '\uFEFF// Main\n// Color: White\n\n'
    '[Event "Opening"]\n[LineID "line-1"]\n[FutureTag "retained"]\n'
    '[Result "*"]\n\n1. e4 {chapter annotation} e5 (1... c5) 2. Nf3 \$1 *\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('renewal-profile-restore-');
  });
  tearDown(() => root.delete(recursive: true));

  test('DATA-06 stopped profile restore preserves cross-store references '
      'and post-cutover work', () async {
    final source = Directory(p.join(root.path, 'source'));
    final documents = Directory(p.join(source.path, 'Documents'));
    final support = await Directory(
      p.join(source.path, 'Support'),
    ).create(recursive: true);
    final oldBook = p.join(documents.path, 'repertoires', 'Book, quoted');
    final oldChapter = p.join(oldBook, 'Main.pgn');
    await File(oldChapter).parent.create(recursive: true);
    await File(oldChapter).writeAsString(_chapter, flush: true);
    final study = File(p.join(documents.path, 'studies', 'Linked.pgn'));
    await study.parent.create();
    await study.writeAsString(
      '[Event "Study"]\n[GameId "source-1"]\n[Result "*"]\n\n1. e4 e5 *',
      flush: true,
    );
    final progress = File(
      p.join(documents.path, 'repertoire_move_progress.csv'),
    );
    await progress.writeAsString(
      'repertoire_id,line_id,move_index,correct_streak,learned\n'
      '${encodeTrainingRow([oldChapter, 'line-1', '2', '5', 'true'])}\n',
      flush: true,
    );
    final attempts = File(
      p.join(documents.path, 'repertoire_move_attempts.jsonl'),
    );
    await attempts.writeAsString(
      '${jsonEncode({
        'repertoireId': oldChapter,
        'lineId': 'line-1',
        'correct': true,
        'futureField': {'keep': 7},
      })}\n',
      flush: true,
    );
    await File(p.join(source.path, 'books.json')).writeAsString(
      jsonEncode({
        'white': [oldBook],
        'black': <String>[],
      }),
      flush: true,
    );
    final games = GameStore.open(p.join(support.path, 'app_games.db'));
    games.importPgn(_sourceGame, collection: GameCollections.tactics);
    final before = games.byKey(GameCollections.tactics, 'source-1')!;
    final positionRows = games.raw.select('SELECT * FROM positions').length;
    expect(positionRows, greaterThan(0));
    // Closing the last connection checkpoints committed WAL state. No fixture
    // writer remains live while the database/document snapshot is copied.
    games.close();
    final backup = Directory(p.join(root.path, 'backup'));
    await _copyStoppedProfile(source, backup);
    final restored = Directory(p.join(root.path, 'restored'));
    await _copyStoppedProfile(backup, restored);
    await source.delete(recursive: true);

    final restoredDocs = Directory(p.join(restored.path, 'Documents'));
    final restoredSupport = Directory(p.join(restored.path, 'Support'));
    final restoredChapter = p.join(
      restoredDocs.path,
      'repertoires',
      'Book, quoted',
      'Main.pgn',
    );
    expect(await File(restoredChapter).readAsBytes(), utf8.encode(_chapter));
    final restoredGames = GameStore.open(
      p.join(restoredSupport.path, 'app_games.db'),
    );
    final restoredGame = restoredGames.byKey(
      GameCollections.tactics,
      'source-1',
    )!;
    expect(restoredGame.id, before.id);
    expect(restoredGame.pgn, before.pgn);
    expect(
      restoredGames.raw.select('SELECT * FROM positions').length,
      positionRows,
    );
    expect(
      restoredGames.raw.select('PRAGMA user_version').single.columnAt(0),
      gameStoreSchemaVersion,
    );
    expect(
      restoredGames.raw.select('PRAGMA integrity_check').single.columnAt(0),
      'ok',
    );
    expect(restoredGames.raw.select('PRAGMA foreign_key_check'), isEmpty);
    expect(
      await File(
        p.join(restoredDocs.path, 'studies', 'Linked.pgn'),
      ).readAsString(),
      contains('[GameId "source-1"]'),
    );

    // Relocation is explicit: absolute chapter/book references cannot merely be
    // copied to a new profile and then declared usable.
    final books = PersistedRepertoireBooks(
      _BooksFile(File(p.join(restored.path, 'books.json'))),
    );
    await RepertoireReferenceMigration(
      restoredDocs,
      books: books,
    ).repoint(documents.path, restoredDocs.path, 'restore-fixture');
    expect(books.state.committed!.white, [p.dirname(restoredChapter)]);
    final restoredProgress = await File(
      p.join(restoredDocs.path, p.basename(progress.path)),
    ).readAsString();
    expect(decodeTrainingRow(trainingRows(restoredProgress).single, 5), [
      restoredChapter,
      'line-1',
      '2',
      '5',
      'true',
    ]);
    final restoredAttempt =
        jsonDecode(
              (await File(
                p.join(restoredDocs.path, p.basename(attempts.path)),
              ).readAsString()).trim(),
            )
            as Map<String, dynamic>;
    expect(restoredAttempt['repertoireId'], restoredChapter);
    expect(restoredAttempt['lineId'], 'line-1');
    expect(restoredAttempt['futureField'], {'keep': 7});

    final storage = IOStorageService(
      documentsRoot: restoredDocs,
      supportRoot: restoredSupport,
    );
    final legacy = LegacyPgnDocumentStore(storage);
    final native = NativePgnDocumentStore();
    final baseline = (await native.open(restoredChapter) as PgnOpened).snapshot;
    final edited = '${baseline.content}\n{created after adapter cutover}\n';
    expect(await native.save(baseline, edited), isA<PgnSaved>());
    restoredGames.importPgn(
      _sourceGame.replaceAll('source-1', 'source-2'),
      collection: GameCollections.tactics,
    );
    restoredGames.close();

    // A compatible adapter rollback reopens current data. It never restores
    // the older backup over annotations or games created after cutover.
    final reopened = (await legacy.open(restoredChapter) as PgnOpened).snapshot;
    expect(reopened.content, edited);
    final latest = '$edited\n{saved after rollback}\n';
    expect(await legacy.save(reopened, latest), isA<PgnSaved>());
    expect(
      (await native.open(restoredChapter) as PgnOpened).snapshot.content,
      latest,
    );
    final restartedGames = GameStore.open(
      p.join(restoredSupport.path, 'app_games.db'),
    );
    try {
      expect(restartedGames.count(GameCollections.tactics), 2);
      expect(
        restartedGames.byKey(GameCollections.tactics, 'source-1')!.id,
        before.id,
      );
      expect(
        restartedGames.byKey(GameCollections.tactics, 'source-2'),
        isNotNull,
      );
    } finally {
      restartedGames.close();
    }
    expect(
      await File(
        p.join(
          backup.path,
          'Documents',
          'repertoires',
          'Book, quoted',
          'Main.pgn',
        ),
      ).readAsBytes(),
      utf8.encode(_chapter),
    );
  }, skip: !Platform.isLinux);
}
