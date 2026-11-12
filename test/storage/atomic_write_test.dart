import 'dart:io';

import 'package:chess_auto_prep/storage/atomic_write.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('atomic'));
  tearDown(() => dir.delete(recursive: true));

  test('a staged copy is named after its file, hashed past 180 bytes', () {
    final fits = '${'a' * 176}.pgn';
    expect(
      temporaryPathFor(p.join(dir.path, fits)),
      p.join(dir.path, '.$fits.v2-tmp'),
    );
    final long = '${'a' * 177}.pgn';
    final staged = p.basename(temporaryPathFor(p.join(dir.path, long)));
    expect(staged, matches(RegExp(r'^\.[0-9a-f]{64}\.v2-tmp$')));
  });

  group('a replace that fails', () {
    Future<void> failWith(String path, int code) => runWithNativeCalls(
      <T>(call, paths, real) => call == NativeCall.replaceFile
          ? throw FileSystemException(
              'replace failed',
              path,
              OSError('injected', code),
            )
          : real(),
      () => replaceFile(path, [1, 2, 3]),
    );

    for (final code in [1176, 1177]) {
      test('part way through ($code) keeps the staged copy', () async {
        final path = p.join(dir.path, 'Main.pgn');
        File(path).writeAsStringSync('old');
        await expectLater(
          failWith(path, code),
          throwsA(isA<FileSystemException>()),
        );
        expect(File(temporaryPathFor(path)).existsSync(), isTrue);
        expect(File(path).readAsStringSync(), 'old');
      });
    }

    test('outright takes the staged copy with it', () async {
      final path = p.join(dir.path, 'Main.pgn');
      File(path).writeAsStringSync('old');
      await expectLater(failWith(path, 5), throwsA(isA<FileSystemException>()));
      expect(File(temporaryPathFor(path)).existsSync(), isFalse);
      expect(File(path).readAsStringSync(), 'old');
    });
  });

  test('stale staged copies go; nothing else does', () async {
    final outside = File(p.join(dir.path, 'outside.pgn'))
      ..writeAsStringSync('kept');
    final folder = Directory(p.join(dir.path, 'folder'))..createSync();
    String at(String name) => p.join(folder.path, name);
    File(at('.Main.pgn.v2-tmp')).writeAsStringSync('stale');
    File(at('Main.pgn.v2-tmp')).writeAsStringSync('not hidden');
    File(at('.Main.pgn')).writeAsStringSync('not staged');
    File(at('Main.pgn')).writeAsStringSync('document');
    Directory(at('.folder.v2-tmp')).createSync();
    Link(at('.link.v2-tmp')).createSync(outside.path);

    await removeStaleTemporaries(folder);

    expect(folder.listSync().map((e) => p.basename(e.path)).toSet(), {
      'Main.pgn.v2-tmp',
      '.Main.pgn',
      'Main.pgn',
      '.folder.v2-tmp',
      '.link.v2-tmp',
    });
    expect(outside.readAsStringSync(), 'kept');
  });

  test('a folder that is not there has nothing stale', () async {
    await removeStaleTemporaries(Directory(p.join(dir.path, 'missing')));
    expect(Directory(p.join(dir.path, 'missing')).existsSync(), isFalse);
  });

  group('a folder flush', () {
    Future<void> failingWith(int code) => syncDirectoryWhereSupported(
      dir.path,
      (path) async =>
          throw FileSystemException('flush failed', path, OSError('', code)),
    );

    for (final code in [22, 95, 38]) {
      test('the filesystem does not offer ($code) is skipped', () async {
        await failingWith(code);
      });
    }

    test('that fails any other way throws', () async {
      await expectLater(failingWith(5), throwsA(isA<FileSystemException>()));
    });
  }, skip: Platform.isLinux ? false : 'Linux error numbers');
}
