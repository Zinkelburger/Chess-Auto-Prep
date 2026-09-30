// How a recorded operation is carried: looked at whole before anything is
// applied, pivots put back when another writer took one, references
// followed alone once an operation that waited too long stops guarding
// (`<id>.following`), and a retry with a fresh id taking a pending record
// over.
@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/compound_write.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/file_relocation.dart';
import 'package:chess_auto_prep/storage/journal_records.dart';
import 'package:chess_auto_prep/storage/operation_id.dart';
import 'package:chess_auto_prep/storage/operation_journal.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:chess_auto_prep/storage/recovery_ledger.dart';
import 'package:chess_auto_prep/storage/recovery_quarantine.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/faulty_disk/fault_plan.dart';
import '../support/faulty_disk/faulty_disk.dart';
import '../support/faulty_disk/io_trace.dart';
import 'store_fixture.dart';

void main() {
  group('finishParticipants', () {
    test('nothing is applied while a pivot cannot be read', () async {
      final first = _Part('first', const HoldsBefore());
      final second = _Part('second', const CannotTell('held open'));
      final settlement = await finishParticipants((
        pivots: [first, second],
        references: const [],
      ));
      expect(settlement, isA<Deferred>());
      expect((settlement as Deferred).phase, Phase.pivots);
      expect(first.log, isEmpty);
    });

    test('nothing is applied while a reference cannot be read', () async {
      final pivot = _Part('pivot', const HoldsBefore());
      final rows = _Part('rows', const CannotTell('no permission for now'));
      expect(
        await finishParticipants((pivots: [pivot], references: [rows])),
        isA<Deferred>(),
      );
      expect(pivot.log, isEmpty);
      expect(rows.log, isEmpty);
    });

    test(
      'a reference that changed is followed, not a reason to stop',
      () async {
        final pivot = _Part('pivot', const HoldsBefore());
        final rows = _Part('rows', const HoldsOther('trained since'));
        expect(
          await finishParticipants((pivots: [pivot], references: [rows])),
          isA<Finished>(),
        );
        expect(pivot.log, ['apply', 'settle']);
        expect(rows.log, ['follow']);
      },
    );

    test(
      'a pivot taken meanwhile puts back the one applied before it',
      () async {
        final first = _Part('first', const HoldsBefore());
        final second = _Part('second', const HoldsBefore())
          ..failApply = const PivotTaken('the name was taken');
        final rows = _Part('rows', const HoldsBefore());
        final settlement = await finishParticipants((
          pivots: [first, second],
          references: [rows],
        ));
        expect(settlement, isA<SetAside>());
        expect(first.log, ['apply', 'putBack']);
        expect(first.holds, isA<HoldsBefore>());
        expect(rows.log, isEmpty);
      },
    );

    test('a passing failure applying a pivot is deferred as it is', () async {
      final first = _Part('first', const HoldsBefore());
      final second = _Part('second', const HoldsBefore())
        ..failApply = const FileSystemException('busy');
      final settlement = await finishParticipants((
        pivots: [first, second],
        references: const [],
      ));
      expect(settlement, isA<Deferred>());
      expect(first.log, ['apply']);
    });

    test(
      'once every pivot has landed a failure is in the references',
      () async {
        final pivot = _Part('pivot', const HoldsAfter());
        final rows = _Part('rows', const HoldsBefore());
        final failing = _FailingReference();
        final settlement = await finishParticipants((
          pivots: [pivot],
          references: [rows, failing],
        ));
        expect((settlement as Deferred).phase, Phase.references);
        expect(pivot.log, ['settle']);
      },
    );

    test('following leaves the pivots as they are and follows', () async {
      final pivot = _Part('pivot', const HoldsOther('saved over since'));
      final rows = _Part('rows', const HoldsBefore());
      expect(
        await finishParticipants((
          pivots: [pivot],
          references: [rows],
        ), following: true),
        isA<Finished>(),
      );
      expect(pivot.log, isNot(contains('apply')));
      expect(rows.log, ['follow']);
    });
  });
  group('the following marker', () {
    late Directory support;
    late Directory journal;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('journal-marker-');
      journal = await Directory(
        p.join(support.path, 'relocation-writes'),
      ).create();
    });
    tearDown(() => support.delete(recursive: true));

    File file(String name) => File(p.join(journal.path, name));

    Future<List<String>> read() async => [
      for (final (_, id) in await readJournal(
        journal,
        decode: (value, id) {
          if (value is! Map<String, Object?> || value['id'] != id) {
            throw const FormatException('not this record');
          }
          return id;
        },
      ))
        id,
    ];

    List<String> quarantined() {
      final folder = Directory(p.join(support.path, quarantineFolder));
      if (!folder.existsSync()) return [];
      return [
        for (final entry in folder.listSync(recursive: true))
          if (entry is File) p.basename(entry.path),
      ];
    }

    test('a marker beside its record is kept and the record read', () async {
      await file('a.json').writeAsString(jsonEncode({'id': 'a'}));
      await file('a.following').writeAsString('');
      expect(await read(), ['a']);
      expect(file('a.following').existsSync(), isTrue);
      expect(quarantined(), isEmpty);
    });

    test('a marker without its record is removed', () async {
      await file('a.following').writeAsString('');
      expect(await read(), isEmpty);
      expect(file('a.following').existsSync(), isFalse);
      expect(quarantined(), isEmpty);
    });

    test('a damaged record is set aside with its marker', () async {
      await file('a.json').writeAsString('{damaged');
      await file('a.following').writeAsString('');
      expect(await read(), isEmpty);
      expect(
        quarantined(),
        unorderedEquals([
          'relocation-writes-a.json',
          'relocation-writes-a.following',
        ]),
      );
    });

    test('a finished record takes its marker with it', () async {
      await file('a.json').writeAsString(jsonEncode({'id': 'a'}));
      await file('a.following').writeAsString('');
      await forgetRecord(file('a.json'));
      expect(journal.listSync(), isEmpty);
    });

    test(
      'an older build sets the marker aside and still reads the record',
      () async {
        await file('a.json').writeAsString(jsonEncode({'id': 'a'}));
        await file('a.following').writeAsString('');
        expect(await _olderReadJournal(journal), ['a']);
        expect(file('a.json').existsSync(), isTrue);
        expect(quarantined(), ['relocation-writes-a.following']);
      },
    );
  });
  group('an operation owed too long', () {
    late StoreFixture fixture;
    late DocumentRef a;
    late DocumentRef b;
    late Revision revision;
    late DateTime now;
    const id = 'owed-move';

    setUp(() async {
      fixture = await StoreFixture.create();
      a = fixture.ref('repertoires/Course/A.pgn');
      b = fixture.ref('repertoires/Course/B.pgn');
      revision = await fixture.put(a, oneGame('1. e4'));
      await fixture.train(a);
      now = DateTime.now();
    });
    tearDown(() => fixture.dispose());

    File record() =>
        File(p.join(fixture.support.path, 'relocation-writes', '$id.json'));
    File marker() => File(
      p.join(fixture.support.path, 'relocation-writes', '$id.following'),
    );

    /// A store whose moves stop at [step] every time, as while another
    /// program keeps a file open, and whose clock the test moves.
    PgnFileStore stopping(FileRelocationStep step) => PgnFileStore(
      documents: fixture.documents,
      support: fixture.support,
      relocationHook: (reached) async {
        if (reached == step) {
          throw const FileSystemException('held open by another program');
        }
      },
      recoveryClock: () => now,
    );

    test('in the references, saves pass and moves wait', () async {
      final store = stopping(FileRelocationStep.reviews);
      expect(
        await store.move(a, b, expected: revision, operationId: id),
        isA<IoFailure>(),
      );
      final saved = oneGame('1. d4');
      Future<SaveResult> save() => store.save(
        b,
        saved,
        expected: revision,
        scope: const WholeDocument(),
      );
      expect(await save(), isA<IoFailure>());
      expect(marker().existsSync(), isFalse);

      now = now.add(const Duration(minutes: 6));
      expect(await save(), isA<Saved>());
      expect(marker().existsSync(), isTrue);
      final c = fixture.ref('repertoires/Course/C.pgn');
      expect(
        await store.move(b, c, expected: await fixture.revisionOf(b)),
        isA<IoFailure>(),
      );

      // Once nothing stops it, the rows follow the file the user saved.
      await FileRelocations(
        documents: fixture.documents,
        support: fixture.support,
      ).recover();
      expect(record().existsSync(), isFalse);
      expect(marker().existsSync(), isFalse);
      expect(fixture.quarantined(), isEmpty);
      expect(await File(b.path).readAsString(), saved);
      await fixture.expectTrained(b);
    });

    test('in the pivots, the move is set aside and nothing moved', () async {
      final store = PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
        relocationHook: stopOnceAt(FileRelocationStep.intent.name),
        recoveryClock: () => now,
      );
      expect(
        await store.move(a, b, expected: revision, operationId: id),
        isA<IoFailure>(),
      );
      // Its rows cannot be read for now, so the move cannot land.
      final reviews = p.join(fixture.documents.path, reviewsFile);
      await Process.run('chmod', ['000', reviews]);
      addTearDown(() => Process.run('chmod', ['644', reviews]));
      final saved = oneGame('1. d4');
      Future<SaveResult> save() => store.save(
        a,
        saved,
        expected: revision,
        scope: const WholeDocument(),
      );
      expect(await save(), isA<IoFailure>());

      now = now.add(const Duration(minutes: 6));
      expect(await save(), isA<Saved>());
      await Process.run('chmod', ['644', reviews]);
      expect(record().existsSync(), isFalse);
      expect(fixture.quarantined(), hasLength(1));
      expect(await File(a.path).readAsString(), saved);
      expect(File(b.path).existsSync(), isFalse);
      await fixture.expectTrained(a);
    });

    test('in the pivots, a folder holding a file that stays unreadable is set '
        'aside and saves beside it pass', () async {
      final sibling = fixture.ref('repertoires/Course/S.pgn');
      final siblingRevision = await fixture.put(sibling, oneGame('1. c4'));
      final store = PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
        relocationHook: stopOnceAt(FileRelocationStep.intent.name),
        recoveryClock: () => now,
      );
      final moved = p.join(fixture.documents.path, 'repertoires', 'Moved');
      expect(
        await store.moveFolder(p.dirname(a.path), moved, operationId: id),
        isA<FolderMoveFailed>(),
      );
      // Another program keeps one chapter unreadable for good.
      await Process.run('chmod', ['000', a.path]);
      addTearDown(() => Process.run('chmod', ['644', a.path]));
      final saved = oneGame('1. d4');
      Future<SaveResult> save() => store.save(
        sibling,
        saved,
        expected: siblingRevision,
        scope: const WholeDocument(),
      );
      expect(await save(), isA<IoFailure>());

      now = now.add(const Duration(minutes: 6));
      expect(await save(), isA<Saved>());
      expect(record().existsSync(), isFalse);
      expect(fixture.quarantined(), hasLength(1));
      expect(Directory(moved).existsSync(), isFalse);
      expect(await File(sibling.path).readAsString(), saved);
    });

    File pair(String extension) => File(
      p.join(fixture.support.path, 'compound-writes', 'owed-pair$extension'),
    );

    /// A store whose line moves stop, as while another program keeps a file
    /// open, when they reach [step] and [failing] says so.
    PgnFileStore pairStopping(
      CompoundWriteStep step, {
      bool Function()? failing,
    }) {
      var stopped = false;
      return PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
        compoundHook: (reached) async {
          if (reached != step || !(failing?.call() ?? !stopped)) return;
          stopped = true;
          throw const FileSystemException('held open by another program');
        },
        recoveryClock: () => now,
      );
    }

    /// Moves A's trained line to B, whose text was [bRevision].
    Future<SaveResult> moveLine(PgnFileStore store, Revision bRevision) async {
      // An attempt names its line, or the move cannot tell it is not this.
      await File(p.join(fixture.documents.path, attemptsFile)).writeAsString(
        '${jsonEncode({'repertoireId': a.path, 'lineId': 'line'})}\n',
      );
      return store.savePair(
        DocumentEdit(
          ref: a,
          text: oneGame('1. e4 e5'),
          expected: revision,
          scope: const WholeDocument(),
          movedLines: const {'line': 'moved'},
        ),
        DocumentEdit(
          ref: b,
          text: oneGame('1. d4 d5'),
          expected: bRevision,
          scope: const WholeDocument(),
        ),
        operationId: 'owed-pair',
      );
    }

    test(
      'in the pivots, a pair whose second PGN stays unreadable is undone and '
      'saves to the first pass',
      () async {
        final bBefore = oneGame('1. d4');
        final store = pairStopping(CompoundWriteStep.document);
        expect(
          await moveLine(store, await fixture.put(b, bBefore)),
          isA<IoFailure>(),
        );
        final aAfter = await File(a.path).readAsString();
        // Another program keeps B unreadable for good.
        await Process.run('chmod', ['000', b.path]);
        addTearDown(() => Process.run('chmod', ['644', b.path]));
        final saved = oneGame('1. c4');
        Future<SaveResult> save() => store.save(
          a,
          saved,
          expected: revision,
          scope: const WholeDocument(),
        );
        expect(await save(), isA<IoFailure>());

        now = now.add(const Duration(minutes: 6));
        expect(await save(), isA<Saved>());
        await Process.run('chmod', ['644', b.path]);
        expect(pair('.json').existsSync(), isFalse);
        expect(fixture.quarantined(), hasLength(1));
        expect(fixture.keptTexts(a), contains(aAfter));
        expect(await File(a.path).readAsString(), saved);
        expect(await File(b.path).readAsString(), bBefore);
      },
      skip: Platform.environment['USER'] == 'root',
    );

    test(
      'in the pivots, a pair whose first PGN stays unreadable guards it alone '
      'and is undone once it reads',
      () async {
        final store = pairStopping(CompoundWriteStep.document);
        final bBefore = oneGame('1. d4');
        final bRevision = await fixture.put(b, bBefore);
        expect(await moveLine(store, bRevision), isA<IoFailure>());
        final aAfter = await File(a.path).readAsString();
        // A landed, the line taken out, and another program keeps it
        // unreadable; B was never written.
        await Process.run('chmod', ['000', a.path]);
        addTearDown(() => Process.run('chmod', ['644', a.path]));
        final saved = oneGame('1. c4');
        Future<SaveResult> save() => store.save(
          b,
          saved,
          expected: bRevision,
          scope: const WholeDocument(),
        );
        expect(await save(), isA<IoFailure>());

        now = now.add(const Duration(minutes: 6));
        expect(await save(), isA<Saved>());
        expect(pair('.json').existsSync(), isTrue);
        expect(pair('.aside').existsSync(), isFalse);
        expect(
          RecoveryLedger.of(
            fixture.support,
          ).owing(CompoundWrites.journal, 'owed-pair')?.paths,
          {a.path},
        );

        await Process.run('chmod', ['644', a.path]);
        await CompoundWrites(
          documents: fixture.documents,
          support: fixture.support,
        ).recover();
        // The line is back in A alone, and what A held is kept.
        expect(pair('.json').existsSync(), isFalse);
        expect(fixture.quarantined(), hasLength(1));
        expect(await File(a.path).readAsString(), oneGame('1. e4'));
        expect(await File(b.path).readAsString(), saved);
        expect(fixture.keptTexts(a), contains(aAfter));
      },
      skip: Platform.environment['USER'] == 'root',
    );

    test('in the references, a pair whose second PGN stays unreadable lets '
        'saves pass and finishes once it reads', () async {
      final store = pairStopping(CompoundWriteStep.training);
      expect(
        await moveLine(store, await fixture.put(b, oneGame('1. d4'))),
        isA<IoFailure>(),
      );
      await Process.run('chmod', ['000', b.path]);
      addTearDown(() => Process.run('chmod', ['644', b.path]));
      final saved = oneGame('1. c4');
      final landed = await fixture.revisionOf(a);
      Future<SaveResult> save() =>
          store.save(a, saved, expected: landed, scope: const WholeDocument());
      expect(await save(), isA<IoFailure>());

      now = now.add(const Duration(minutes: 6));
      expect(await save(), isA<Saved>());
      expect(pair('.following').existsSync(), isTrue);
      await Process.run('chmod', ['644', b.path]);
      await CompoundWrites(
        documents: fixture.documents,
        support: fixture.support,
      ).recover();
      expect(pair('.json').existsSync(), isFalse);
      expect(pair('.following').existsSync(), isFalse);
      expect(fixture.quarantined(), isEmpty);
      expect(await File(a.path).readAsString(), saved);
      expect(await File(b.path).readAsString(), oneGame('1. d4 d5'));
    }, skip: Platform.environment['USER'] == 'root');

    test('in the pivots, an undone pair whose record cannot be moved aside is '
        'never carried out again', () async {
      final bBefore = oneGame('1. d4');
      var failing = true;
      final store = pairStopping(
        CompoundWriteStep.document,
        failing: () => failing,
      );
      expect(
        await moveLine(store, await fixture.put(b, bBefore)),
        isA<IoFailure>(),
      );
      final aBefore = oneGame('1. e4');
      now = now.add(const Duration(minutes: 6));
      // Nothing can be moved into quarantine while the edit is undone.
      final run = await FaultyDisk(fixture.root).run(
        lastingFault(
          (op) =>
              op.kind == IoKind.rename &&
              (op.to ?? '').contains(quarantineFolder),
          IoError.eacces,
        ),
        () => store.recovery.access(
          Saves([a.path]),
          () async => 'saved',
          owed: (detail) => detail,
        ),
      );
      expect(
        run.end,
        isA<Returned<String>>().having((end) => end.value, 'value', 'saved'),
      );
      expect(await File(a.path).readAsString(), aBefore);
      expect(pair('.json').existsSync(), isTrue);
      expect(pair('.aside').existsSync(), isTrue);
      final ledger = RecoveryLedger.of(fixture.support);
      expect(ledger.owing(CompoundWrites.journal, 'owed-pair')?.paths, isEmpty);

      // A restart, with nothing in the way now.
      failing = false;
      await CompoundWrites(
        documents: fixture.documents,
        support: fixture.support,
      ).recover();
      expect(await File(a.path).readAsString(), aBefore);
      expect(await File(b.path).readAsString(), bBefore);
      expect(pair('.json').existsSync(), isFalse);
      expect(pair('.aside').existsSync(), isFalse);
      expect(fixture.quarantined(), hasLength(1));
      expect(ledger.owing(CompoundWrites.journal, 'owed-pair'), isNull);
    });

    test('in the references, histories owed at the handover are carried once, '
        'and a chapter made at the old name since keeps its own', () async {
      final edited = oneGame('1. e4 e5');
      expect(await fixture.replace(a, edited, revision), isA<Saved>());
      final store = stopping(FileRelocationStep.reviews);
      expect(
        await store.move(
          a,
          b,
          expected: await fixture.revisionOf(a),
          operationId: id,
        ),
        isA<IoFailure>(),
      );
      now = now.add(const Duration(minutes: 6));
      expect(
        await store.save(
          b,
          oneGame('1. d4'),
          expected: await fixture.revisionOf(b),
          scope: const WholeDocument(),
        ),
        isA<Saved>(),
      );
      // A pass moves the owed histories, then stops in the rows again.
      await FileRelocations(
        documents: fixture.documents,
        support: fixture.support,
        testHook: (step) async {
          if (step == FileRelocationStep.reviews) {
            throw const FileSystemException('held open by another program');
          }
        },
      ).recover();
      expect(
        Directory(p.join(fixture.support.path, 'backup-moves')).listSync(),
        isEmpty,
      );
      expect(fixture.backupFolder(a).existsSync(), isFalse);

      // A new chapter at the old name, saved twice.
      final newA = oneGame('1. c4');
      final created = await store.create(a, newA) as Created;
      expect(
        await store.save(
          a,
          oneGame('1. c4 c5'),
          expected: created.revision,
          scope: const WholeDocument(),
        ),
        isA<Saved>(),
      );
      expect(
        await store.save(
          a,
          oneGame('1. c4 e5'),
          expected: await fixture.revisionOf(a),
          scope: const WholeDocument(),
        ),
        isA<Saved>(),
      );
      final newVersions = fixture.keptTexts(a);
      expect(newVersions, contains(newA));

      await FileRelocations(
        documents: fixture.documents,
        support: fixture.support,
      ).recover();
      expect(record().existsSync(), isFalse);
      expect(marker().existsSync(), isFalse);
      expect(fixture.quarantined(), isEmpty);
      expect(fixture.keptTexts(b), containsAll([oneGame('1. e4'), edited]));
      expect(fixture.keptTexts(b), isNot(contains(newA)));
      expect(fixture.keptTexts(a), newVersions);
      expect(
        Directory(p.join(p.dirname(a.path), '.cap-pgn-history')).existsSync(),
        isFalse,
      );
    });

    test('in the references, the kept versions merge with those saves kept '
        'since, and no chapter is offered back', () async {
      final edited = oneGame('1. e4 e5');
      expect(await fixture.replace(a, edited, revision), isA<Saved>());
      final store = stopping(FileRelocationStep.reviews);
      expect(
        await store.move(
          a,
          b,
          expected: await fixture.revisionOf(a),
          operationId: id,
        ),
        isA<IoFailure>(),
      );
      now = now.add(const Duration(minutes: 6));
      expect(
        await store.save(
          b,
          oneGame('1. d4'),
          expected: await fixture.revisionOf(b),
          scope: const WholeDocument(),
        ),
        isA<Saved>(),
      );

      await FileRelocations(
        documents: fixture.documents,
        support: fixture.support,
      ).recover();
      expect(record().existsSync(), isFalse);
      expect(fixture.quarantined(), isEmpty);
      expect(fixture.backupFolder(a).existsSync(), isFalse);
      expect(fixture.keptTexts(b), containsAll([oneGame('1. e4'), edited]));
      expect(
        Directory(p.join(p.dirname(a.path), '.cap-pgn-history')).existsSync(),
        isFalse,
      );
    });
  });
  group('a process killed', () {
    late StoreFixture fixture;
    late DocumentRef a;
    late DocumentRef b;
    late DocumentRef c;
    const saved = '[Event "Saved"]\n[Result "*"]\n\n1. d4 *\n';

    setUp(() async {
      fixture = await StoreFixture.create();
      a = fixture.ref('repertoires/Course/A.pgn');
      b = fixture.ref('repertoires/Course/B.pgn');
      c = fixture.ref('repertoires/Course/C.pgn');
      await fixture.put(a, oneGame('1. e4'));
      await fixture.train(a);
    });
    tearDown(() => fixture.dispose());

    Future<void> killAfter(String scenario) async {
      final folder = await Directory(
        p.join(Directory.current.path, '.dart_tool'),
      ).createTemp('operation-journal-process-');
      addTearDown(() => folder.delete(recursive: true));
      final script = await File(
        p.join(folder.path, 'owe.dart'),
      ).writeAsString(_driver);
      final process = await Process.start('dart', [
        'run',
        '--packages=${p.join(Directory.current.path, '.dart_tool', 'package_config.json')}',
        script.path,
        fixture.documents.path,
        fixture.support.path,
        a.path,
        b.path,
        c.path,
        scenario,
      ], workingDirectory: Directory.current.path);
      final said = StringBuffer();
      final ready = Completer<void>();
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            said.writeln(line);
            if (line == 'checkpoint durable' && !ready.isCompleted) {
              ready.complete();
            }
          });
      final errors = process.stderr.transform(utf8.decoder).listen(said.write);
      unawaited(
        process.exitCode.then((code) {
          if (!ready.isCompleted) {
            ready.completeError(StateError('Child exited $code: $said'));
          }
        }),
      );
      try {
        await ready.future.timeout(const Duration(seconds: 60));
      } finally {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 10));
        await output.cancel();
        await errors.cancel();
      }
      expect(said.toString(), contains('as it should'));
    }

    test('after its rows stopped guarding and the moved file was saved, the '
        'restart finishes the move', () async {
      await killAfter('escalate');
      await FileRelocations(
        documents: fixture.documents,
        support: fixture.support,
      ).recover();
      expect(fixture.unfinishedMoves(), isEmpty);
      expect(
        Directory(p.join(fixture.support.path, 'relocation-writes')).listSync(),
        isEmpty,
      );
      expect(fixture.quarantined(), isEmpty);
      expect(await File(b.path).readAsString(), saved);
      await fixture.expectTrained(b);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('with one move pending and the next refused, the restart finishes the '
        'first and the next works', () async {
      await killAfter('refused');
      final store = PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
      );
      expect(
        await store.move(b, c, expected: await fixture.revisionOf(b)),
        isA<Moved>(),
      );
      expect(fixture.quarantined(), isEmpty);
      expect(File(a.path).existsSync(), isFalse);
      await fixture.expectTrained(c);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  test('a fresh-id retry of a pending move takes it over', () async {
    final fixture = await StoreFixture.create();
    addTearDown(fixture.dispose);
    final a = fixture.ref('repertoires/Course/A.pgn');
    final b = fixture.ref('repertoires/Course/B.pgn');
    final revision = await fixture.put(a, oneGame('1. e4'));
    await fixture.train(a);
    var armed = true;
    final owner = FileRelocations(
      documents: fixture.documents,
      support: fixture.support,
      testHook: (step) async {
        if (armed && step == FileRelocationStep.reviews) {
          armed = false;
          throw const FileSystemException('held open by another program');
        }
      },
    );
    expect(
      await owner.move(a, b, expected: revision, operationId: 'first'),
      isA<IoFailure>(),
    );
    // The caller lost the first id and asks for the same move again.
    expect(
      await owner.move(a, b, expected: revision, operationId: 'second'),
      isA<Moved>(),
    );
    // A retry that lost the answer is answered the same.
    expect(
      await owner.move(a, b, expected: revision, operationId: 'second'),
      isA<Moved>(),
    );
    expect(fixture.unfinishedMoves(), isEmpty);
    expect(fixture.quarantined(), isEmpty);
    await fixture.expectTrained(b);
  });
}

/// A pivot or reference that answers what a test tells it to.
final class _Part implements Pivot, Reference {
  _Part(this.name, this.holds);

  final String name;
  Holds holds;
  Object? failApply;
  final log = <String>[];

  @override
  Set<String> get paths => {name};

  @override
  Future<Holds> look() async => holds;

  @override
  Future<void> apply() async {
    if (failApply case final error?) throw error;
    log.add('apply');
    holds = const HoldsAfter();
  }

  @override
  Future<void> settle() async => log.add('settle');

  @override
  Future<bool> putBack() async {
    if (holds is! HoldsAfter) return false;
    log.add('putBack');
    holds = const HoldsBefore();
    return true;
  }

  @override
  Future<void> follow() async => log.add('follow');
}

final class _FailingReference implements Reference {
  @override
  Future<Holds> look() async => const HoldsBefore();

  @override
  Future<void> follow() =>
      Future.error(const FileSystemException('held open by another program'));
}

/// readJournal as builds before the marker read a folder: whatever is not
/// `<id>.json` is not a record and is set aside.
Future<List<String>> _olderReadJournal(Directory directory) async {
  final entries = directory.listSync()
    ..sort((a, b) => a.path.compareTo(b.path));
  final records = <String>[];
  for (final entry in entries) {
    final name = p.basename(entry.path);
    try {
      if (entry is! File || p.extension(name) != '.json') {
        throw const FormatException('not a journal record');
      }
      final id = OperationId(p.basenameWithoutExtension(name));
      final value = jsonDecode(utf8.decode(await entry.readAsBytes()));
      if (value is! Map || value['id'] != id) {
        throw const FormatException('not this record');
      }
      records.add(id);
    } on Object catch (error) {
      await quarantine(directory.parent, entry, error);
    }
  }
  return records;
}

/// Moves A to B with its reviews held open by another program every time,
/// then either saves B once the move has waited too long, or asks to move
/// B on to C, and says so before it waits to be killed.
const _driver = r'''
import 'dart:io';
import 'package:chess_auto_prep/storage/document_probe.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/file_relocation.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';

Future<void> main(List<String> args) async {
  final a = DocumentRef(args[2]);
  final b = DocumentRef(args[3]);
  final c = DocumentRef(args[4]);
  final escalate = args[5] == 'escalate';
  var ahead = Duration.zero;
  final store = PgnFileStore(
    documents: Directory(args[0]),
    support: Directory(args[1]),
    relocationHook: (step) async {
      if (step == FileRelocationStep.reviews) {
        throw const FileSystemException('held open by another program');
      }
    },
    recoveryClock: () => DateTime.now().add(ahead),
  );
  final revision = (await probeDocument(a.path) as FileFound).revision;
  if (await store.move(a, b, expected: revision) is! IoFailure) {
    throw StateError('The move did not stop at the reviews.');
  }
  if (escalate) ahead = const Duration(minutes: 6);
  final Object result = escalate
      ? await store.save(b, '[Event "Saved"]\n[Result "*"]\n\n1. d4 *\n',
          expected: revision, scope: const WholeDocument())
      : await store.move(b, c, expected: revision);
  if (escalate ? result is Saved : result is IoFailure) {
    stdout.writeln('${result.runtimeType} as it should');
  } else {
    throw StateError('Unexpected $result');
  }
  stdout.writeln('checkpoint durable');
  await Future<void>.delayed(const Duration(minutes: 5));
}
''';
