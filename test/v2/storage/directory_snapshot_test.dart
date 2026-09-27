import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/directory_snapshot.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late Directory root;
  const binary = [0, 255, 128, 42];
  final nested = p.join('nested', 'Main.PGN');
  File file(String relative) => File(p.join(root.path, relative));
  Future<void> populate() async {
    await Directory(p.join(root.path, 'empty')).create(recursive: true);
    await Directory(p.join(root.path, 'nested')).create();
    await file(nested).writeAsString('[Event "Line"]\n\n1. d4 *');
    await file('raw_games.bin').writeAsBytes(binary);
    await Directory(p.join(root.path, '.cap-pgn-history')).create();
    await file(
      p.join('.cap-pgn-history', '1750000000000000-a-Old.pgn'),
    ).writeAsString('kept');
    await Directory(
      p.join(root.path, '.generation', 'empty'),
    ).create(recursive: true);
    await file(
      p.join('.generation', 'bundle.json'),
    ).writeAsString('{"future":true}');
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('directory-snapshot-');
    root = Directory(p.join(temporary.path, 'Course'));
    await root.create();
  });
  tearDown(() => temporary.delete(recursive: true));

  test('captures all entries and verifies after the directory moves', () async {
    await populate();
    final snapshot = await DirectorySnapshot.capture(root.path);
    final paths = snapshot.entries.map((entry) => entry.path).toList();
    final expected = [
      'empty',
      'nested',
      nested,
      'raw_games.bin',
      '.cap-pgn-history',
      p.join('.cap-pgn-history', '1750000000000000-a-Old.pgn'),
      '.generation',
      p.join('.generation', 'empty'),
      p.join('.generation', 'bundle.json'),
    ]..sort();
    expect(paths, expected);
    expect(
      snapshot.entries.singleWhere((entry) => entry.path == 'empty').kind,
      DirectoryEntryKind.directory,
    );
    expect(
      snapshot.entries
          .singleWhere((entry) => entry.path == 'raw_games.bin')
          .sha256,
      sha256.convert(binary).toString(),
    );
    final serialized = jsonDecode(jsonEncode(snapshot.toJson()));
    final restored = DirectorySnapshot.fromJson(
      serialized,
      identity: snapshot.identity,
    );
    expect(restored.toJson(), snapshot.toJson());
    await restored.verify(root.path);
    final moved = await root.rename(p.join(temporary.path, 'Renamed'));
    await restored.verify(moved.path);
    expect(
      await File(p.join(moved.path, 'raw_games.bin')).readAsBytes(),
      binary,
    );
  });

  test('an empty root has a native identity and empty inventory', () async {
    final snapshot = await DirectorySnapshot.capture(root.path);
    expect(snapshot.identity, isNotEmpty);
    expect(snapshot.entries, isEmpty);
    await snapshot.verify(root.path);
  });

  test('POSIX backslashes stay literal filename characters', () async {
    const name = r'side\car.bin';
    await file(name).writeAsBytes(binary);
    final snapshot = await DirectorySnapshot.capture(root.path);
    expect(snapshot.entries.single.path, name);
    await DirectorySnapshot.fromJson(
      snapshot.toJson(),
      identity: snapshot.identity,
    ).verify(root.path);
  }, skip: Platform.isWindows ? 'Backslash is a separator on Windows.' : false);

  test(
    'serialization and caller collections cannot mutate the snapshot',
    () async {
      await populate();
      final original = await DirectorySnapshot.capture(root.path);
      final json = original.toJson();
      final snapshot = DirectorySnapshot.fromJson(
        json,
        identity: original.identity,
      );
      json.first['identity'] = 'changed';
      json.clear();
      final output = snapshot.toJson();
      output.first['path'] = 'changed';
      output.clear();
      expect(snapshot.toJson(), original.toJson());
      expect(() => snapshot.entries.clear(), throwsUnsupportedError);
    },
  );

  for (final mutation in [
    'added file',
    'added directory',
    'changed bytes',
    'missing file',
    'missing empty directory',
    'file identity',
    'directory identity',
    'root identity',
  ]) {
    test('verification refuses $mutation', () async {
      await populate();
      final snapshot = await DirectorySnapshot.capture(root.path);
      switch (mutation) {
        case 'added file':
          await file('new.bin').writeAsBytes(binary);
        case 'added directory':
          await Directory(p.join(root.path, 'new')).create();
        case 'changed bytes':
          await file(nested).writeAsString('another version');
        case 'missing file':
          await file(nested).delete();
        case 'missing empty directory':
          await Directory(p.join(root.path, 'empty')).delete();
        case 'file identity':
          final bytes = await file(nested).readAsBytes();
          await file(nested).rename(p.join(temporary.path, 'original.pgn'));
          await file(nested).writeAsBytes(bytes);
        case 'directory identity':
          await Directory(
            p.join(root.path, 'empty'),
          ).rename(p.join(temporary.path, 'old-empty'));
          await Directory(p.join(root.path, 'empty')).create();
        case 'root identity':
          await root.rename(p.join(temporary.path, 'old-root'));
          await root.create();
          await populate();
      }
      await expectLater(
        snapshot.verify(root.path),
        throwsA(isA<RecoveryRequired>()),
      );
    });
  }

  for (final link in [
    'file',
    'directory',
    'root',
    'dangling',
    'hardlink',
    'fifo',
  ]) {
    test(
      'capture refuses $link without traversing it',
      () async {
        await populate();
        var target = root.path;
        switch (link) {
          case 'file':
            await Link(p.join(root.path, 'linked')).create(file(nested).path);
          case 'directory':
            await Link(p.join(root.path, 'linked')).create(temporary.path);
          case 'root':
            target = p.join(temporary.path, 'alias');
            await Link(target).create(root.path);
          case 'dangling':
            await Link(
              p.join(root.path, 'linked'),
            ).create(p.join(temporary.path, 'missing'));
          case 'hardlink':
            final result = await Process.run('ln', [
              file(nested).path,
              p.join(temporary.path, 'outside-link'),
            ]);
            expect(result.exitCode, 0);
          case 'fifo':
            final result = await Process.run('mkfifo', [
              p.join(root.path, 'pipe'),
            ]);
            expect(result.exitCode, 0);
        }
        await expectLater(
          DirectorySnapshot.capture(target),
          throwsA(isA<RecoveryRequired>()),
        );
        expect(await file(nested).readAsString(), contains('1. d4'));
      },
      skip: Platform.isWindows
          ? 'Native links and POSIX special-file fixtures need host support.'
          : false,
    );
  }

  test('missing or non-directory roots are refused', () async {
    await file('plain').writeAsString('bytes');
    for (final path in [p.join(root.path, 'missing'), file('plain').path]) {
      await expectLater(
        DirectorySnapshot.capture(path),
        throwsA(isA<RecoveryRequired>()),
      );
    }
  });

  final directory = {
    'path': 'folder',
    'kind': 'directory',
    'identity': 'directory-id',
  };
  final plain = {
    'path': 'plain',
    'kind': 'file',
    'identity': 'file-id',
    'sha256': 'a' * 64,
  };
  final invalid = <String, Object?>{
    'non-list': {},
    'non-map entry': ['entry'],
    'empty path': [
      {...plain, 'path': ''},
    ],
    'root entry': [
      {...directory, 'path': '.'},
    ],
    'absolute': [
      {...plain, 'path': p.absolute('plain')},
    ],
    'parent traversal': [
      {...plain, 'path': p.join('..', 'plain')},
    ],
    'unnormalized': [
      {...plain, 'path': 'folder${p.separator}..${p.separator}plain'},
    ],
    'nul': [
      {...plain, 'path': 'bad\u0000'},
    ],
    'unknown field': [
      {...plain, 'future': true},
    ],
    'unknown kind': [
      {...plain, 'kind': 'link'},
    ],
    'missing hash': [
      directory,
      {'path': 'plain', 'kind': 'file', 'identity': 'file-id'},
    ],
    'directory hash': [
      {...directory, 'sha256': 'a' * 64},
    ],
    'bad hash': [
      {...plain, 'sha256': 'A' * 64},
    ],
    'empty identity': [
      {...plain, 'identity': ''},
    ],
    'duplicate path': [plain, plain],
    'unsorted': [plain, directory],
    'missing parent': [
      {...plain, 'path': p.join('folder', 'plain')},
    ],
    'file parent': [
      {...plain, 'path': 'folder'},
      {...plain, 'path': p.join('folder', 'plain'), 'identity': 'child-id'},
    ],
    'duplicate identity': [
      directory,
      {...plain, 'identity': 'directory-id'},
    ],
    'root reused': [
      {...plain, 'identity': 'root-id'},
    ],
  };
  for (final entry in invalid.entries) {
    test('strict decoding refuses ${entry.key}', () {
      expect(
        () => DirectorySnapshot.fromJson(entry.value, identity: 'root-id'),
        throwsA(isA<RecoveryRequired>()),
      );
    });
  }
  test('strict decoding refuses missing root identity', () {
    expect(
      () => DirectorySnapshot.fromJson([], identity: ''),
      throwsA(isA<RecoveryRequired>()),
    );
  });
}
