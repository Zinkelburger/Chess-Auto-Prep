// The native layer under every atomic write, called as the store calls it.
// Each observation is read back from the OS, so the contract the C source
// states — never follow a link, refuse what is not one plain file, replace
// nothing — is checked against a real filesystem rather than trusted.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('v2-native-');
  });
  tearDown(() => root.delete(recursive: true));

  String at(String name) => p.join(root.path, name);

  Future<File> written(String name, String text) =>
      File(at(name)).writeAsString(text);

  /// The volume half of an identity, which is what decides whether a link
  /// can be made between two places.
  Future<String> volumeOf(Directory directory) async =>
      (await observeDirectory(directory.path)).identity!.split(':').first;

  group('observeFile', () {
    test('reads the bytes, their hash and an identity that holds', () async {
      await written('a.pgn', 'hello');
      final first = await observeFile(at('a.pgn'));
      expect(first.status, 0);
      expect(utf8.decode(first.bytes!), 'hello');
      expect(first.sha256Hex, sha256.convert(utf8.encode('hello')).toString());
      expect(first.identity, isNotNull);
      final again = await observeFile(at('a.pgn'));
      expect(again.identity, first.identity);
    });

    test('a missing file is status 1 with nothing in it', () async {
      final observed = await observeFile(at('none.pgn'));
      expect(observed.status, 1);
      expect(observed.bytes, isNull);
      expect(observed.identity, isNull);
      expect(observed.sha256Hex, isNull);
    });

    test('an empty file is a document with no bytes', () async {
      await written('empty.pgn', '');
      final observed = await observeFile(at('empty.pgn'));
      expect(observed.status, 0);
      expect(observed.bytes, isEmpty);
      expect(observed.sha256Hex, sha256.convert(const []).toString());
    });
  });

  group('observeFile refuses', () {
    test('a folder', () async {
      await Directory(at('folder')).create();
      expect((await observeFile(at('folder'))).status, 4);
    });

    test('a link is never followed, whatever it points at', () async {
      await written('real.pgn', 'x');
      await Link(at('link.pgn')).create(at('real.pgn'));
      expect((await observeFile(at('link.pgn'))).status, 4);
      await Link(at('dangling.pgn')).create(at('gone.pgn'));
      expect((await observeFile(at('dangling.pgn'))).status, 4);
    });

    test('a file with a second name is refused', () async {
      // Two names for one inode means a write through one changes the other,
      // and a store that thinks it holds a document holds half of one.
      await written('one.pgn', 'x');
      // Dart makes only symbolic links; a second hard name needs `ln`.
      final linked = await Process.run('ln', [at('one.pgn'), at('two.pgn')]);
      expect(linked.exitCode, 0, reason: '${linked.stderr}');
      expect((await observeFile(at('one.pgn'))).status, 4);
      await File(at('two.pgn')).delete();
      expect((await observeFile(at('one.pgn'))).status, 0);
    });

    test('a file replaced by rename has a new identity; one rewritten in '
        'place keeps it', () async {
      await written('a.pgn', 'one');
      final before = (await observeFile(at('a.pgn'))).identity;
      await File(at('a.pgn')).writeAsString('two');
      expect((await observeFile(at('a.pgn'))).identity, before);
      await (await written('.a.pgn.tmp', 'three')).rename(at('a.pgn'));
      final after = await observeFile(at('a.pgn'));
      expect(utf8.decode(after.bytes!), 'three');
      expect(after.identity, isNot(before));
    });

    test('a NUL in the path is refused before the OS sees it', () async {
      await expectLater(observeFile('${at('a')}\u0000b'), throwsArgumentError);
    });
  });

  group('observeDirectory', () {
    test('a folder keeps its identity through a rename', () async {
      await Directory(at('KID')).create();
      final before = await observeDirectory(at('KID'));
      expect(before.status, 0);
      await Directory(at('KID')).rename(at("King's Indian"));
      final after = await observeDirectory(at("King's Indian"));
      expect(after.identity, before.identity);
      expect((await observeDirectory(at('KID'))).status, 1);
    });

    test('a file, a link to a folder and a missing path are not a folder '
        'of ours', () async {
      await written('a.pgn', 'x');
      await Directory(at('real')).create();
      await Link(at('link')).create(at('real'));
      expect((await observeDirectory(at('a.pgn'))).status, 4);
      expect((await observeDirectory(at('link'))).status, 4);
      expect((await observeDirectory(at('none'))).status, 1);
    });
  });

  group('installNewFile', () {
    test('publishes the staged file under its name and removes the staging '
        'name', () async {
      await written('.a.tmp', 'new');
      await installNewFile(at('.a.tmp'), at('a.pgn'));
      expect(await File(at('a.pgn')).readAsString(), 'new');
      expect(await File(at('.a.tmp')).exists(), isFalse);
    });

    test('a name that is taken is a collision and both files are left as '
        'they were', () async {
      await written('a.pgn', 'old');
      await written('.a.tmp', 'new');
      await expectLater(
        installNewFile(at('.a.tmp'), at('a.pgn')),
        throwsA(isA<NativeNameCollision>()),
      );
      expect(await File(at('a.pgn')).readAsString(), 'old');
      expect(await File(at('.a.tmp')).readAsString(), 'new');
    });
  });

  group('installNewFile refuses', () {
    test('a staged file that is not there, naming the destination', () async {
      await expectLater(
        installNewFile(at('.none.tmp'), at('a.pgn')),
        throwsA(
          isA<FileSystemException>()
              .having((e) => e.path, 'path', at('a.pgn'))
              .having((e) => e.osError?.errorCode, 'errno', 2),
        ),
      );
      expect(await File(at('a.pgn')).exists(), isFalse);
    });

    test(
      'a destination on another filesystem is refused, never copied',
      () async {
        // /dev/shm is its own mount on most Linux machines; when it is not,
        // there is nothing to cross and the case cannot be shown here.
        final other = Directory('/dev/shm');
        if (!Platform.isLinux || !await other.exists()) return;
        if (await volumeOf(other) == await volumeOf(root)) return;
        final there = await other.createTemp('v2-native-');
        addTearDown(() => there.delete(recursive: true));
        await written('.a.tmp', 'x');
        await expectLater(
          installNewFile(at('.a.tmp'), p.join(there.path, 'a.pgn')),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.osError?.errorCode,
              'errno',
              18, // EXDEV
            ),
          ),
        );
        expect(await File(at('.a.tmp')).exists(), isTrue);
        expect(await File(p.join(there.path, 'a.pgn')).exists(), isFalse);
      },
    );
  });

  group('movePathNoReplace', () {
    test('moves a file, and a folder with everything in it', () async {
      await written('a.pgn', 'x');
      await movePathNoReplace(at('a.pgn'), at('b.pgn'));
      expect(await File(at('b.pgn')).readAsString(), 'x');
      expect(await File(at('a.pgn')).exists(), isFalse);
      await Directory(at('KID')).create();
      await written('KID/Main.pgn', 'y');
      await movePathNoReplace(at('KID'), at('Kings Indian'));
      expect(await File(at('Kings Indian/Main.pgn')).readAsString(), 'y');
      expect(await Directory(at('KID')).exists(), isFalse);
    });

    test('never replaces what is at the destination, even an empty '
        'folder', () async {
      await written('a.pgn', 'a');
      await written('b.pgn', 'b');
      await expectLater(
        movePathNoReplace(at('a.pgn'), at('b.pgn')),
        throwsA(isA<NativeNameCollision>()),
      );
      expect(await File(at('b.pgn')).readAsString(), 'b');
      await Directory(at('from')).create();
      await Directory(at('to')).create();
      await expectLater(
        movePathNoReplace(at('from'), at('to')),
        throwsA(isA<NativeNameCollision>()),
      );
      expect(await Directory(at('from')).exists(), isTrue);
    });

    test(
      'a source that is not there is an error, not a silent success',
      () async {
        await expectLater(
          movePathNoReplace(at('none'), at('b')),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.osError?.errorCode,
              'errno',
              2,
            ),
          ),
        );
      },
    );
  });

  group('syncDirectory', () {
    test('flushes a folder, and refuses a path that is not one', () async {
      await Directory(at('KID')).create();
      await syncDirectory(at('KID'));
      await written('a.pgn', 'x');
      await expectLater(
        syncDirectory(at('a.pgn')),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        syncDirectory(at('none')),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
