import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/backup_relocation.dart';
import 'package:chess_auto_prep/v2/storage/backups.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late BackupArchive archive;
  const from = '1111111111111111';
  const to = '2222222222222222';
  const copyName = '.index.json.v2-tmp.previous-123-1780000000000000';
  const path = '/Documents/repertoires/Moved.pgn';
  File index(String id) =>
      File(p.join(archive.folderFor(id).path, 'index.json'));
  File copy(String id, [String name = copyName]) =>
      File(p.join(archive.folderFor(id).path, name));
  Future<void> keep() async {
    final bytes = utf8.encode('saved history');
    expect(
      await archive.record(
        id: from,
        documentPath: '/old/Main.pgn',
        bytes: bytes,
        hash: sha256.convert(bytes).toString(),
      ),
      isA<BackupRecorded>(),
    );
  }

  Future<BackupMove> plan() => archive.planMove(
    fromId: from,
    toId: to,
    documentPath: path,
    operationId: 'move-index',
  );
  BackupMove reload(BackupMove move) => BackupMove.fromJson(
    jsonDecode(jsonEncode(move.toJson())) as Map<String, Object?>,
  );
  Future<void> stop(BackupMove move, {bool published = false}) => expectLater(
    archive.applyMove(
      move,
      testHook: (step) async {
        if (step ==
            (published
                ? BackupMoveStep.indexPublished
                : BackupMoveStep.sourceMoved)) {
          throw StateError('lost acknowledgement');
        }
      },
    ),
    throwsA(isA<RecoveryRequired>()),
  );

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('backup-index-copy-');
    archive = BackupArchive(Directory(p.join(temporary.path, 'backups')));
  });
  tearDown(() => temporary.delete(recursive: true));

  for (final marked in [false, true]) {
    for (final published in [false, true]) {
      test(
        'known native index copies survive recovery: BOM=$marked after=$published',
        () async {
          await keep();
          final raw = await index(from).readAsString();
          if (marked) await index(from).writeAsString('\ufeff$raw');
          final before = await index(from).readAsBytes();
          final move = await plan();
          await stop(move, published: published);
          await copy(to).writeAsBytes(before);
          final second = copy(
            to,
            '.index.json.v2-tmp.previous-456-1780000000000001',
          );
          await second.writeAsBytes(before);
          await archive.validateMove(reload(move));
          await archive.applyMove(reload(move));
          await archive.applyMove(reload(move));
          expect(await index(to).readAsString(), move.indexAfter);
          expect(await copy(to).readAsBytes(), before);
          expect(await second.readAsBytes(), before);
        },
      );
    }
  }

  for (final corruption in [
    'different bytes',
    'missing BOM',
    'bad name',
    'wrong pid',
    'symlink',
    'missing captured entry',
  ]) {
    test(
      'unknown index evidence is refused: $corruption',
      () async {
        await keep();
        final raw = await index(from).readAsString();
        await index(from).writeAsString('\ufeff$raw');
        final before = await index(from).readAsBytes();
        final move = await plan();
        await stop(move, published: true);
        final retained = copy(to, switch (corruption) {
          'bad name' => 'index.json.previous-123-1780000000000000',
          'wrong pid' => '.index.json.v2-tmp.previous-0-1780000000000000',
          _ => copyName,
        });
        if (corruption == 'symlink') {
          final external = File(p.join(temporary.path, 'external.json'));
          await external.writeAsBytes(before);
          await Link(retained.path).create(external.path);
        } else {
          await retained.writeAsBytes(switch (corruption) {
            'different bytes' => utf8.encode(move.indexAfter!),
            'missing BOM' => utf8.encode(raw),
            _ => before,
          });
        }
        if (corruption == 'missing captured entry') {
          final version = archive
              .folderFor(to)
              .listSync()
              .whereType<File>()
              .singleWhere((file) => file.path.endsWith('.pgn'));
          await version.delete();
        }
        final committed = await index(to).readAsBytes();
        await expectLater(
          archive.applyMove(reload(move)),
          throwsA(isA<RecoveryRequired>()),
        );
        expect(await index(to).readAsBytes(), committed);
        expect(
          await FileSystemEntity.type(retained.path, followLinks: false),
          isNot(FileSystemEntityType.notFound),
        );
      },
      skip: corruption == 'symlink' && Platform.isWindows
          ? 'Symlink privilege not assumed.'
          : false,
    );
  }

  test(
    'copies captured before the move remain exact inventory participants',
    () async {
      await keep();
      final old = await index(from).readAsBytes();
      await copy(from).writeAsBytes(old);
      final move = await plan();
      await stop(move, published: true);
      await copy(to).delete();
      // A different legitimate recovery copy does not replace the missing one.
      await copy(
        to,
        '.index.json.v2-tmp.previous-789-1780000000000002',
      ).writeAsBytes(old);
      await expectLater(
        archive.applyMove(reload(move)),
        throwsA(isA<RecoveryRequired>()),
      );
    },
  );

  test(
    'new copies at the unmoved source are not this index publication',
    () async {
      await keep();
      final old = await index(from).readAsBytes();
      final move = await plan();
      await copy(from).writeAsBytes(old);
      await expectLater(
        archive.applyMove(move),
        throwsA(isA<RecoveryRequired>()),
      );
      expect(await archive.folderFor(from).exists(), isTrue);
      expect(await archive.folderFor(to).exists(), isFalse);
    },
  );
}
