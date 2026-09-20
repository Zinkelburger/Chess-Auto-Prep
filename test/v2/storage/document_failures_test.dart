// What goes wrong to real files: two writers for one name, an editor outside
// the app, an interrupted write, a file that cannot be read and a folder that
// cannot be written.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;

  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test('two creates of one name in one app: one wins, one collides', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final results = await Future.wait([
      fixture.store.create(ref, 'first *\n'),
      fixture.store.create(ref, 'second *\n'),
    ]);
    expect(results.whereType<Created>(), hasLength(1));
    expect(results.whereType<Collision>(), hasLength(1));
    final kept = await File(ref.path).readAsString();
    expect(kept, anyOf('first *\n', 'second *\n'));
  });

  test(
    'two creates of one name from two processes: one wins, one collides',
    () async {
      await Directory(
        p.dirname(fixture.ref('KID/Main.pgn').path),
      ).create(recursive: true);
      final answers = await Future.wait([
        _spawnCreate(fixture, 'first *\n'),
        _spawnCreate(fixture, 'second *\n'),
      ]);
      expect(answers..sort(), ['collision', 'created']);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a conflicted save keeps the draft, which saves once it is rebased',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      final loaded = await fixture.put(ref, 'theirs *\n');
      await File(ref.path).writeAsString('edited elsewhere *\n');
      const draft = 'my draft *\n';
      expect(await fixture.replace(ref, draft, loaded), isA<Conflict>());
      expect(await File(ref.path).readAsString(), 'edited elsewhere *\n');
      final current = (await fixture.store.open(ref) as Opened).revision;
      expect(await fixture.replace(ref, draft, current), isA<Saved>());
      expect(await File(ref.path).readAsString(), draft);
    },
  );

  test('undo is a save of the receipt, and the next undo uses the receipt it '
      'returned', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final first = await fixture.put(ref, 'A *\n');
    final toB = (await fixture.replace(ref, 'B *\n', first) as Saved).receipt;
    final toC =
        (await fixture.replace(ref, 'C *\n', toB.committed) as Saved).receipt;
    final undoneC = await fixture.replace(ref, toC.before, toC.committed);
    expect(await File(ref.path).readAsString(), 'B *\n');
    // The entry for B now expects what undoing C committed, not the old rB.
    expect(
      await fixture.replace(ref, toB.before, toB.committed),
      isA<Conflict>(),
    );
    final rearmed = (undoneC as Saved).receipt.committed;
    expect(await fixture.replace(ref, toB.before, rearmed), isA<Saved>());
    expect(await File(ref.path).readAsString(), 'A *\n');
  });

  test('an edit from outside between B and C: undoing C restores it and the '
      'older entry stays disarmed', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final first = await fixture.put(ref, 'A *\n');
    final toB = (await fixture.replace(ref, 'B *\n', first) as Saved).receipt;
    await File(ref.path).writeAsString('E *\n');
    final reopened = (await fixture.store.open(ref) as Opened).revision;
    final toC =
        (await fixture.replace(ref, 'C *\n', reopened) as Saved).receipt;
    expect(await fixture.replace(ref, toC.before, toC.committed), isA<Saved>());
    expect(await File(ref.path).readAsString(), 'E *\n');
    expect(
      await fixture.replace(ref, toB.before, toB.committed),
      isA<Conflict>(),
    );
    expect(await File(ref.path).readAsString(), 'E *\n');
  });

  test(
    'a staged copy left by an interrupted write is never the document',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      final revision = await fixture.put(ref, 'real *\n');
      final staged = File(temporaryPathFor(ref.path));
      await staged.writeAsString('half written');
      expect((await fixture.store.open(ref) as Opened).text, 'real *\n');
      expect(await fixture.replace(ref, 'newer *\n', revision), isA<Saved>());
      expect(await File(ref.path).readAsString(), 'newer *\n');
      expect(await staged.exists(), isFalse);
    },
  );

  test(
    'a file this process may not read is unreadable, and saving over it fails',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      final revision = await fixture.put(ref, 'secret *\n');
      await Process.run('chmod', ['000', ref.path]);
      final opened = await fixture.store.open(ref);
      expect(opened, isA<Unreadable>());
      expect((opened as Unreadable).detail, isNotEmpty);
      expect(
        await fixture.replace(ref, 'mine *\n', revision),
        isA<IoFailure>(),
      );
    },
    skip: _needsAPlainUser,
  );

  test(
    'a save into a folder that cannot be written fails and changes nothing',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      final revision = await fixture.put(ref, 'kept *\n');
      await Process.run('chmod', ['500', p.dirname(ref.path)]);
      final result = await fixture.replace(ref, 'new *\n', revision);
      expect(result, isA<IoFailure>());
      expect((result as IoFailure).detail, isNotEmpty);
      expect(await File(ref.path).readAsString(), 'kept *\n');
    },
    skip: _needsAPlainUser,
  );

  test('a create in a folder that cannot be written fails', () async {
    await fixture.put(fixture.ref('KID/Main.pgn'), 'kept *\n');
    final folder = p.dirname(fixture.ref('KID/Main.pgn').path);
    await Process.run('chmod', ['500', folder]);
    expect(
      await fixture.store.create(fixture.ref('KID/Second.pgn'), 'new *\n'),
      isA<IoFailure>(),
    );
    expect(await File(p.join(folder, 'Second.pgn')).exists(), isFalse);
  }, skip: _needsAPlainUser);
}

final Object _needsAPlainUser =
    !Platform.isLinux || Platform.environment['USER'] == 'root'
    ? 'needs a Linux user without root'
    : false;

Future<String> _spawnCreate(StoreFixture fixture, String text) async {
  final process = await Process.start('dart', [
    'run',
    p.join('test', 'v2', 'storage', 'harness', 'create_document.dart'),
    fixture.documents.path,
    fixture.support.path,
    fixture.ref('KID/Main.pgn').path,
    text,
  ], workingDirectory: Directory.current.path);
  process.stderr.transform(utf8.decoder).listen(stderr.write);
  return process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstWhere((line) => line == 'created' || line.startsWith('collision'));
}
