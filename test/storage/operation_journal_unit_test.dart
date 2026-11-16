// The journal itself, over pivots a test scripts: what a run, an adoption,
// a finish of overlapping records and a stop of guarding decide from what
// each pivot answers.
import 'dart:io';

import 'package:chess_auto_prep/storage/operation_journal.dart';
import 'package:chess_auto_prep/storage/operation_participants.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

enum _Step { prepared, intent, completed }

final class _Record implements Recorded {
  _Record(this.id);

  @override
  final String id;

  @override
  Map<String, Object?> get json => {'id': id};
}

final class _Pivot implements Pivot {
  _Pivot(this.name);

  final String name;
  Holds holds = const HoldsBefore();
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
  Future<void> settle() async {}

  @override
  Future<void> putBack() async {
    if (holds is! HoldsAfter) return;
    log.add('putBack');
    holds = const HoldsBefore();
  }
}

void main() {
  late Directory support;
  late List<_Pivot> pivots;
  Future<void> Function(_Record)? prepare;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('journal-');
    pivots = [_Pivot('a')];
    prepare = null;
  });
  tearDown(() => support.delete(recursive: true));

  OperationJournal<_Record> journal() => OperationJournal<_Record>(
    name: 'tests',
    support: support,
    decode: (_, id) => _Record(id),
    participants: (_, {following = false}) =>
        (pivots: pivots, references: const []),
    steps: (
      prepared: _Step.prepared,
      intent: _Step.intent,
      completed: _Step.completed,
    ),
    prepare: (record) async => prepare?.call(record),
  );

  File recordFile(String id) => File(p.join(support.path, 'tests', '$id.json'));

  /// Leaves [id] recorded and unfinished: its first pivot fails for now.
  Future<void> leaveRecorded(OperationJournal<_Record> owner, String id) async {
    pivots.first.failApply = const FileSystemException('held open');
    expect(await owner.run(_Record(id)), isA<Deferred>());
    expect(recordFile(id).existsSync(), isTrue);
    pivots.first.failApply = null;
  }

  test('an operation this process finished is named as done', () async {
    final owner = journal();
    expect(await owner.run(_Record('one')), isA<Finished>());
    expect((await owner.named('one'))?.done, isTrue);
  });

  test('a run that fails before its record is written is refused, not '
      'deferred', () async {
    prepare = (_) => throw const FileSystemException('disk full');
    final settlement = await journal().run(_Record('one'));
    expect(settlement, isA<Refused>());
    expect((settlement as Refused).reason, isA<NotWritten>());
  });

  test('a run whose pivot is taken for good waits for the next pass rather '
      'than being set aside', () async {
    pivots.first.failApply = const PivotTaken('another file took the name');
    expect(await journal().run(_Record('one')), isA<Deferred>());
    expect(recordFile('one').existsSync(), isTrue);
  });

  test(
    'an adopted operation whose pivot is taken for good waits too',
    () async {
      final owner = journal();
      await leaveRecorded(owner, 'one');
      pivots.first.failApply = const PivotTaken('another file took the name');
      final (_, settlement) = (await owner.adopt('two', (_) => true))!;
      expect(settlement, isA<Deferred>());
      expect(recordFile('one').existsSync(), isTrue);
    },
  );

  test('finishing overlapping operations leaves the others recorded', () async {
    final owner = journal();
    await leaveRecorded(owner, 'one');
    expect(await owner.finishOverlapping((_) => false), isNull);
    expect(pivots.first.log, isEmpty);
    expect((await owner.named('one'))?.done, isFalse);
  });

  test('a first pivot another writer changed after the edit landed puts '
      'nothing back when guarding stops', () async {
    pivots = [_Pivot('a'), _Pivot('b')];
    final owner = journal();
    pivots.last.failApply = const FileSystemException('held open');
    expect(await owner.run(_Record('one')), isA<Deferred>());
    pivots.first.holds = const HoldsOther('another program saved it');
    pivots.last.holds = const HoldsAfter();
    await owner.stopGuarding('one');
    expect(pivots.last.log, isNot(contains('putBack')));
    expect(pivots.last.holds, isA<HoldsAfter>());
  });
}
