import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/compound_write.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:chess_auto_prep/storage/recovery_ledger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;
  late RecoveryLedger ledger;
  final now = DateTime.utc(2026, 9, 29, 12);

  setUp(() async {
    fixture = await StoreFixture.create();
    ledger = RecoveryLedger.of(fixture.support);
  });
  tearDown(() => fixture.dispose());

  /// Leaves [id] owed over [paths] with its record on disk, and keeps every
  /// pass and try away for an hour, so nothing finishes it meanwhile.
  Future<File> hold(String id, Set<String> paths) async {
    final record = File(
      p.join(fixture.support.path, CompoundWrites.journal, '$id.json'),
    );
    await record.parent.create(recursive: true);
    await record.writeAsString('{}');
    ledger
      ..deferred(
        CompoundWrites.journal,
        id,
        paths: paths,
        detail: 'held open by another program',
        now: DateTime.now(),
      )
      ..passCouldNotRun(
        DateTime.now(),
        const Duration(hours: 1),
        locked: false,
      );
    return record;
  }

  Future<String> save(RecoveryGate gate, String path) =>
      gate.access(Saves({path}), () async => 'saved', owed: (detail) => detail);

  test('one ledger per Support folder, whatever its spelling', () async {
    final alias = Link(p.join(fixture.root.path, 'alias'));
    await alias.create(fixture.support.path);
    expect(RecoveryLedger.of(Directory(alias.path)), same(ledger));
  });

  test('an operation is tried three times at once, then less often', () {
    Duration wait(int attempts) {
      for (var i = 0; i < attempts; i++) {
        ledger.deferred(
          'compound-writes',
          'edit',
          paths: const {'/a'},
          detail: 'held',
          now: now,
        );
      }
      final owed = ledger.owing('compound-writes', 'edit')!;
      ledger.settled('compound-writes', 'edit');
      return owed.next.difference(owed.tried);
    }

    expect([for (var n = 1; n <= 3; n++) wait(n)], everyElement(Duration.zero));
    expect(
      [for (var n = 4; n <= 10; n++) wait(n).inSeconds],
      [5, 10, 20, 40, 80, 160, 300],
    );
    expect(wait(100), const Duration(minutes: 5));
  });

  test('a pass kept out by a lock waits longer each time', () {
    const base = Duration(seconds: 30);
    final waits = <int>[];
    for (var i = 0; i < 6; i++) {
      ledger.passCouldNotRun(now, base, locked: true);
      expect(ledger.waiting(now), isTrue);
      final free = [
        for (var s = 0; s <= 480; s += 30) now.add(Duration(seconds: s)),
      ].firstWhere((at) => !ledger.waiting(at));
      waits.add(free.difference(now).inSeconds);
    }
    expect(waits, [30, 60, 120, 240, 480, 480]);
    // A pass that took its locks but stopped part way waits the base again.
    ledger.passCouldNotRun(now, base, locked: false);
    expect(ledger.waiting(now.add(const Duration(seconds: 29))), isTrue);
    expect(ledger.waiting(now.add(base)), isFalse);
    ledger.passCouldNotRun(now, base, locked: true);
    expect(ledger.waiting(now.add(base)), isFalse);
  });

  test('a pass is due first, then only for something new or due', () async {
    final none = await ledger.list(const [CompoundWrites.journal]);
    expect(ledger.passDue(now, none), isTrue);
    ledger.passRan(none);
    expect(ledger.passDue(now, none), isFalse);

    final record = File(
      p.join(fixture.support.path, CompoundWrites.journal, 'new.json'),
    );
    await record.parent.create(recursive: true);
    await record.writeAsString('{}');
    final listed = await ledger.list(const [CompoundWrites.journal]);
    expect(listed.records, {(CompoundWrites.journal, 'new')});
    expect(ledger.passDue(now, listed), isTrue);
    ledger.passRan(listed);
    expect(ledger.passDue(now, listed), isFalse);

    for (var i = 0; i < 4; i++) {
      ledger.deferred(
        CompoundWrites.journal,
        'new',
        paths: const {'/a'},
        detail: 'held',
        now: now,
      );
    }
    expect(ledger.passDue(now, listed), isFalse);
    expect(ledger.passDue(now.add(const Duration(seconds: 5)), listed), isTrue);
  });

  test(
    'a record written directly while idle is finished by the next access',
    () async {
      final ref = fixture.ref('repertoires/Main.pgn');
      await fixture.put(ref, oneGame('1. d4'));
      expect(await fixture.store.open(ref), isA<Opened>());
      final canonical = await File(ref.path).resolveSymbolicLinks();
      final record = File(
        p.join(fixture.support.path, CompoundWrites.journal, 'direct.json'),
      );
      await record.parent.create(recursive: true);
      await record.writeAsString(
        jsonEncode({
          'version': 1,
          'id': 'direct',
          'state': 'committing',
          'documentPath': canonical,
          'documentBefore': oneGame('1. d4'),
          'documentAfter': oneGame('1. e4'),
          'booksBefore': null,
          'booksAfter': null,
        }),
      );

      final opened = await fixture.store.open(
        fixture.ref('repertoires/Other.pgn'),
      );
      expect(opened, isA<Absent>());
      expect(await record.exists(), isFalse);
      expect(await File(ref.path).readAsString(), oneGame('1. e4'));
      expect(fixture.quarantined(), isEmpty);
    },
  );

  test('a finished record that cannot be removed yet guards nothing', () async {
    final gate = fixture.store.recovery;
    final ref = fixture.ref('repertoires/Main.pgn');
    await fixture.put(ref, oneGame('1. e4'));
    final canonical = await File(ref.path).resolveSymbolicLinks();
    final folder = p.join(fixture.support.path, CompoundWrites.journal);
    final record = File(p.join(folder, 'leftover.json'));
    await record.parent.create(recursive: true);
    await record.writeAsString(
      jsonEncode({
        'version': 1,
        'id': 'leftover',
        'state': 'complete',
        'documentPath': canonical,
        'documentBefore': oneGame('1. d4'),
        'documentAfter': oneGame('1. e4'),
        'booksBefore': null,
        'booksAfter': null,
      }),
    );
    // The record cannot be deleted while its folder is read-only.
    await Process.run('chmod', ['555', folder]);
    try {
      expect(await save(gate, canonical), 'saved');
      expect(ledger.owing(CompoundWrites.journal, 'leftover')?.paths, isEmpty);
      expect(await record.exists(), isTrue);
    } finally {
      await Process.run('chmod', ['755', folder]);
    }
  }, skip: Platform.isWindows);

  test('an owed id another process finished is dropped', () async {
    final gate = fixture.store.recovery;
    final path = fixture.ref('repertoires/Main.pgn').path;
    final record = await hold('elsewhere', {path});
    expect(await save(gate, path), stillFinishing);
    await record.delete();
    expect(await save(gate, path), 'saved');
    expect(ledger.owing(CompoundWrites.journal, 'elsewhere'), isNull);
  });

  test('guards a file in an owed folder and a folder over an owed file', () {
    ledger.deferred(
      'relocation-writes',
      'folder',
      paths: const {'/docs/Old', '/docs/New'},
      detail: 'held',
      now: now,
    );
    ledger.deferred(
      'compound-writes',
      'file',
      paths: const {'/docs/Course/Main.pgn'},
      detail: 'held',
      now: now,
    );
    String? named(String path) => ledger.naming({path}).firstOrNull?.id;
    expect(named('/docs/Old/Main.pgn'), 'folder');
    expect(named('/docs/New'), 'folder');
    expect(named('/docs/Course'), 'file');
    expect(named('/docs/Course/Main.pgn'), 'file');
    expect(named('/docs/Older/Main.pgn'), isNull);
    expect(named('/docs/Course/Main.pgn.bak'), isNull);
    expect(named('/docs/Course/Other.pgn'), isNull);
  });

  test('guards through the configured spelling of Documents', () async {
    final alias = Link(p.join(fixture.root.path, 'alias'));
    await alias.create(fixture.documents.path);
    final gate = RecoveryGate(
      documents: Directory(alias.path),
      support: fixture.support,
    );
    final real = await fixture.documents.resolveSymbolicLinks();
    await hold('aliased', {p.join(real, 'repertoires', 'Main.pgn')});
    final spelled = p.join(alias.path, 'repertoires', 'Main.pgn');
    expect(await save(gate, spelled), stillFinishing);
    expect(await save(gate, p.join(alias.path, 'repertoires')), stillFinishing);
    expect(
      await save(gate, p.join(alias.path, 'repertoires', 'Other.pgn')),
      'saved',
    );
  }, skip: Platform.isWindows);

  test('saves pass an operation that let them; records never do', () async {
    final gate = fixture.store.recovery;
    final path = fixture.ref('repertoires/Main.pgn').path;
    await hold('following', {path});
    ledger.savesMayPass(CompoundWrites.journal, 'following');
    expect(await save(gate, path), 'saved');
    expect(
      await gate.access(
        Records({path}),
        () async => 'recorded',
        owed: (detail) => detail,
      ),
      stillFinishing,
    );
    expect(
      await gate.access(Reads({path}), () async => 'read', owed: (d) => d),
      'read',
    );
  });

  test('keeps the newest 256 receipts of each journal', () {
    for (var i = 0; i < 256; i++) {
      expect(ledger.remember('compound-writes', 'edit-$i', i), isNull);
    }
    ledger.remember('relocation-writes', 'move', 'kept');
    // Reading a receipt makes it the newest.
    expect(ledger.receipt<int>('compound-writes', 'edit-0'), 0);
    expect(ledger.remember('compound-writes', 'edit-256', 256), 'edit-1');
    expect(ledger.receipt<int>('compound-writes', 'edit-1'), isNull);
    expect(ledger.receipt<int>('compound-writes', 'edit-0'), 0);
    expect(ledger.receipt<int>('compound-writes', 'edit-256'), 256);
    expect(ledger.receipt<String>('relocation-writes', 'move'), 'kept');
  });
}
