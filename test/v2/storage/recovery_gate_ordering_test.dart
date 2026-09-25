import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/storage/document_probe.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/file_relocation.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:chess_auto_prep/v2/storage/compound_commit.dart';
import 'package:chess_auto_prep/v2/storage/compound_write.dart';
import 'package:chess_auto_prep/v2/storage/recovery_gate.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;
  late File document;
  late RecoveryGate gate;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('training-gate-');
    documents = await Directory(p.join(root.path, 'Documents')).create();
    support = await Directory(p.join(root.path, 'Support')).create();
    document = await File(
      p.join(documents.path, 'Main.pgn'),
    ).writeAsString('[Event "Before"]\n\n1. e4 *\n');
    gate = RecoveryGate(documents: documents, support: support);
  });
  tearDown(() => root.delete(recursive: true));

  Future<File> pendingCompound([
    CompoundWriteStep interrupt = CompoundWriteStep.intent,
  ]) async {
    final owner = CompoundWrites(
      documents: documents,
      support: support,
      testHook: (step) async {
        if (step == interrupt) throw StateError('lost intent ack');
      },
    );
    await expectLater(
      owner.commit(
        CompoundCommit(
          id: 'rename',
          documentPath: document.path,
          documentBefore: await document.readAsString(),
          documentAfter: '[Event "After"]\n\n1. e4 *\n',
          booksBefore: null,
          booksAfter: null,
        ),
      ),
      throwsStateError,
    );
    return File(p.join(support.path, 'compound-writes', 'rename.json'));
  }

  Future<void> queueAttempt([String id = 'answer']) async {
    final source = await probeDocument(document.path) as FileFound;
    final attempt = Attempt(
      key: (source: document.path, id: 'line'),
      ply: 0,
      fen: Fen.initial,
      played: 'd4',
      expected: 'e4',
      correct: false,
      phase: AttemptPhase.learning,
      at: DateTime.utc(2026, 9, 25),
    );
    await gate.training.enqueue(
      id: id,
      payload: jsonEncode(['attempt', encodeAttempt(attempt)]),
      sources: {document.path: source.revision},
    );
  }

  Future<File> pendingNamespace(String kind) async {
    if (kind == 'compound') return pendingCompound();
    if (kind == 'prepared compound') {
      return pendingCompound(CompoundWriteStep.prepared);
    }
    final source = await probeDocument(document.path) as FileFound;
    final target = p.join(documents.path, 'Moved.pgn');
    if (kind == 'old note') {
      await gate.notes.record(
        'move',
        from: document.path,
        to: target,
        identity: source.identity,
        folder: false,
      );
      return File(p.join(support.path, 'unfinished-moves', 'move.json'));
    }
    final owner = FileRelocations(
      documents: documents,
      support: support,
      testHook: (step) async {
        if (step == FileRelocationStep.intent)
          throw StateError('lost move ack');
      },
    );
    expect(
      await owner.move(
        DocumentRef(document.path),
        DocumentRef(target),
        expected: source.revision,
        operationId: 'move',
      ),
      isA<IoFailure>(),
    );
    return File(p.join(support.path, 'relocation-writes', 'move.json'));
  }

  test(
    'normal access drains accepted training before entering action',
    () async {
      await queueAttempt();
      expect(await gate.training.inspect(), isTrue);
      final result = await gate.run(() async {
        expect(await gate.training.inspect(), isFalse);
        return File(p.join(documents.path, attemptsFile)).readAsString();
      });
      expect(const LineSplitter().convert(result), hasLength(1));
      await gate.run(() async {});
      expect(
        await File(p.join(documents.path, attemptsFile)).readAsString(),
        result,
      );
    },
  );

  test('enqueue lane preserves pending training without replay', () async {
    await queueAttempt();
    final note = File(p.join(support.path, 'training-writes', 'answer.json'));
    final before = await note.readAsBytes();
    var entered = false;
    await gate.run(() async => entered = true, recoverTraining: false);
    expect(entered, isTrue);
    expect(await gate.training.inspect(), isTrue);
    expect(await note.readAsBytes(), before);
    expect(await File(p.join(documents.path, attemptsFile)).exists(), isFalse);
  });

  for (final kind in [
    'compound',
    'prepared compound',
    'relocation',
    'old note',
  ]) {
    for (final drain in [true, false]) {
      test(
        'mixed pending $kind refuses before replay (drain=$drain)',
        () async {
          final namespace = await pendingNamespace(kind);
          await queueAttempt();
          final namespaceBefore = await namespace.readAsBytes();
          final training = File(
            p.join(support.path, 'training-writes', 'answer.json'),
          );
          final trainingBefore = await training.readAsBytes();
          var entered = false;
          await expectLater(
            gate.run(() async => entered = true, recoverTraining: drain),
            throwsA(isA<RecoveryRequired>()),
          );
          expect(entered, isFalse);
          expect(await namespace.readAsBytes(), namespaceBefore);
          expect(await training.readAsBytes(), trainingBefore);
          expect(await document.readAsString(), contains('Before'));
          expect(
            await File(p.join(documents.path, attemptsFile)).exists(),
            isFalse,
          );
        },
      );
    }
  }

  test('malformed namespace metadata blocks training replay', () async {
    await queueAttempt();
    final namespace = File(p.join(support.path, 'compound-writes', 'bad.json'));
    await namespace.parent.create();
    await namespace.writeAsString('{}');
    var entered = false;
    await expectLater(
      gate.run(() async => entered = true),
      throwsA(isA<RecoveryRequired>()),
    );
    expect(entered, isFalse);
    expect(await gate.training.inspect(), isTrue);
    expect(await File(p.join(documents.path, attemptsFile)).exists(), isFalse);
  });

  test('enqueue lane recovers namespace when no training is pending', () async {
    await pendingCompound();
    await gate.run(() async {
      expect(await document.readAsString(), contains('After'));
      expect(await gate.compounds.inspect(), isFalse);
    }, recoverTraining: false);
  });

  test('invalid training metadata refuses before namespace replay', () async {
    final namespace = await pendingCompound();
    final before = await namespace.readAsString();
    final training = File(p.join(support.path, 'training-writes', 'bad.json'));
    await training.parent.create();
    await training.writeAsString('{"unrecognized":true}');
    var entered = false;
    await expectLater(
      gate.run(() async => entered = true),
      throwsA(isA<RecoveryRequired>()),
    );
    expect(entered, isFalse);
    expect(await namespace.readAsString(), before);
    expect(await document.readAsString(), contains('Before'));
    expect(await training.readAsString(), '{"unrecognized":true}');
  });
}
