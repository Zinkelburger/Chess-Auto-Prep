import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/ui/file_names.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/windows_file_handle.dart';
import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;
  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test(
    'long Unicode paths survive create, save, backup, rename and delete',
    () async {
      final folder = p.join(
        fixture.documents.path,
        'Repertoire ${'a' * 100}',
        'José 棋 ${'b' * 100}',
      );
      final ref = DocumentRef(p.join(folder, '${'c' * 100}.pgn'));
      expect(ref.path.length, greaterThan(300));
      final before = oneGame('1. e4');
      final after = oneGame('1. e4 e5');
      final revision = await fixture.put(ref, before);
      final saved = await fixture.edit(ref, after, revision);
      expect(saved, isA<Saved>());
      expect(fixture.keptTexts(ref), contains(before));
      final reopened = PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
      );
      expect((await reopened.open(ref) as Opened).text, after);
      final next = (saved as Saved).receipt.committed;
      expect(
        await reopened.rename(ref, 'Renamed 棋.pgn', expected: next),
        isA<Moved>(),
      );
      final renamed = DocumentRef(p.join(folder, 'Renamed 棋.pgn'));
      expect((await reopened.open(renamed) as Opened).text, after);
      final deleted = await reopened.delete(renamed, expected: next);
      expect(deleted, isA<Deleted>());
      expect(
        await File((deleted as Deleted).recoveredTo).readAsString(),
        after,
      );
      expect(await File(renamed.path).exists(), isFalse);
    },
  );

  test('imported Unicode names can be saved and quarantined', () async {
    final name = importedName('棋' * 90, fallback: 'Chapter');
    final ref = fixture.ref('$name.pgn');
    final revision = await fixture.put(ref, oneGame('1. d4'));
    expect(await fixture.store.delete(ref, expected: revision), isA<Deleted>());
  });

  test('existing long filenames leave room for a staged replacement', () async {
    final target = p.join(fixture.documents.path, '${'a' * 240}.pgn');
    await replaceFile(target, utf8.encode('before'));
    await replaceFile(target, utf8.encode('after'));
    expect(await File(target).readAsString(), 'after');
    expect(await File(temporaryPathFor(target)).exists(), isFalse);
  });

  test(
    'Windows retries a real sharing violation without losing the old file',
    () async {
      final target = fixture.ref('Shared.pgn').path;
      await replaceFile(target, utf8.encode('before'));
      final reader = WindowsFileHandle(target);
      addTearDown(reader.close);
      final releasing = Timer(const Duration(milliseconds: 300), reader.close);
      addTearDown(releasing.cancel);
      final saving = replaceFile(target, utf8.encode('after'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await File(target).readAsString(), 'before');
      await saving;
      expect(await File(target).readAsString(), 'after');
    },
    skip: !Platform.isWindows,
  );

  test(
    'Windows leaves the document intact when sharing remains denied',
    () async {
      final target = fixture.ref('Blocked.pgn').path;
      await replaceFile(target, utf8.encode('before'));
      final reader = WindowsFileHandle(target);
      try {
        await expectLater(
          replaceFile(target, utf8.encode('after')),
          throwsA(isA<FileSystemException>()),
        );
        expect(await File(target).readAsString(), 'before');
        expect(await File(temporaryPathFor(target)).exists(), isFalse);
      } finally {
        reader.close();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'Windows refuses an external edit made during a sharing retry',
    () async {
      final target = fixture.ref('Changed.pgn').path;
      await replaceFile(target, utf8.encode('before'));
      final reader = WindowsFileHandle(target);
      try {
        final rejected = expectLater(
          replaceFile(target, utf8.encode('our edit')),
          throwsA(isA<FileSystemException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await File(target).writeAsString('external edit');
        await rejected;
        expect(await File(target).readAsString(), 'external edit');
      } finally {
        reader.close();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'Windows replacement retains named streams and protected permissions',
    () async {
      final target = fixture.ref('Permissions 棋.pgn').path;
      await replaceFile(target, utf8.encode('before'));
      await File('$target:review').writeAsString('metadata');
      final protect = await _acl(target, protect: true);
      await replaceFile(target, utf8.encode('after'));
      expect(await File('$target:review').readAsString(), 'metadata');
      expect(await _acl(target), protect);
    },
    skip: !Platform.isWindows,
  );
}

Future<String> _acl(String path, {bool protect = false}) async {
  final command = [
    r'$ErrorActionPreference = "Stop";',
    r'$acl = Get-Acl -LiteralPath $env:CAP_TEST_FILE;',
    if (protect)
      r'$acl.SetAccessRuleProtection($true, $true); Set-Acl -LiteralPath $env:CAP_TEST_FILE -AclObject $acl;',
    r'(Get-Acl -LiteralPath $env:CAP_TEST_FILE).Sddl',
  ].join(' ');
  final result = await Process.run(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-Command', command],
    environment: {'CAP_TEST_FILE': path},
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return '${result.stdout}'.trim();
}
