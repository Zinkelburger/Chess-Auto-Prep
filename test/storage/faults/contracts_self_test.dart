// The contracts, proven before they point at production code: a toy store
// of two files with a journal passes every one of them, and each of six
// seeded defects is flagged by exactly the contract it breaks. That shows
// both directions: no false alarm on the correct toy, and no defect let
// through. Then the Authority table answers for every path the standard
// profile, a section rename and a move produce, and the save discipline
// lints hold on those real traces.
@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/storage/atomic_write.dart';
import 'package:chess_auto_prep/storage/document_probe.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/storage/recovery_quarantine.dart';
import 'package:chess_auto_prep/storage/reference_change.dart';
import 'package:chess_auto_prep/storage/training_rows.dart'
    show reviewsFile, streaksFile;
import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/faulty_disk/contracts.dart';
import '../../support/faulty_disk/fault_plan.dart';
import '../../support/faulty_disk/faulty_disk.dart';
import '../../support/faulty_disk/io_trace.dart';
import '../../support/profile/authority.dart';
import '../../support/profile/profile.dart';
import '../../support/profile/profile_integrity.dart';
import '../../support/profile/profile_snapshot.dart';
import '../../support/profile/standard_profile.dart';

/// What the toy gets wrong, if anything.
enum Defect {
  none,
  inPlaceWrite,
  publishBeforeSync,
  journalRemovedEarly,
  quarantineOnEio,
  duplicateOnRetry,
  derivedFailureFails,
}

const _game = '[Event "New"]\n[Result "*"]\n\n1. c4 e5 *\n';
const _texts = {
  'a.pgn': '[Event "A"]\n[Result "*"]\n\n1. e4 e5 *\n\n',
  'b.pgn': '[Event "B"]\n[Result "*"]\n\n1. d4 d5 *\n\n',
  'c.pgn': '[Event "C"]\n[Result "*"]\n\n1. Nf3 Nf6 *\n\n',
};

/// Adds [_game] to a.pgn and b.pgn as one operation with a fixed id: what
/// each file held before is part of the request, so a retry is the same
/// request.
const _participants = ['a.pgn', 'b.pgn'];

String _sha(List<int> bytes) => '${sha256.convert(bytes)}';

/// Two files changed as one operation under a journal record, the shape of
/// a compound save: record, keep each replaced version, publish each file,
/// remove the record, then write a derived index. Recovery on every access
/// finishes a record left behind. It keeps nothing in memory, so a new
/// instance is a restarted process.
final class Toy {
  Toy(this.profile, this.defect);

  final Profile profile;
  final Defect defect;

  String get _folder => profile.document('toy');
  String get _journal => profile.supportFile('compound-writes');
  String get _kept => profile.supportFile('backups/toy');
  String get derived =>
      profile.document('toy/.cap-generation/i/v2-1/tree.json');
  String _path(String name) => p.join(_folder, name);
  File get _record => File(p.join(_journal, 'op1.json'));

  Future<Verdict> commit() async {
    try {
      await access();
      // A record recovery could not finish yet holds these files.
      if (await _record.exists()) return Verdict.unknown;
      final current = {
        for (final name in _participants) name: await _read(name),
      };
      if (current.values.contains(null)) return Verdict.rejected;
      final after = {
        for (final name in _participants)
          name: defect == Defect.duplicateOnRetry
              ? current[name]! + _game
              : _texts[name]! + _game,
      };
      if (defect != Defect.duplicateOnRetry) {
        if (_participants.every((n) => current[n] == after[n])) {
          await _writeDerived();
          return Verdict.committed;
        }
        if (_participants.any(
          (n) => current[n] != _texts[n] && current[n] != after[n],
        )) {
          return Verdict.rejected;
        }
      }
      await _apply(current, after);
      await _writeDerived();
      return Verdict.committed;
    } on FileSystemException {
      return Verdict.unknown;
    }
  }

  Future<void> _apply(
    Map<String, String?> current,
    Map<String, String> after,
  ) async {
    final record = _record;
    await _publish(
      record.path,
      utf8.encode(
        jsonEncode({
          for (final name in _participants)
            name: {
              'before': _sha(utf8.encode(current[name]!)),
              'after': after[name],
            },
        }),
      ),
    );
    for (final (i, name) in _participants.indexed) {
      if (current[name] == after[name]) continue;
      await _replace(name, utf8.encode(current[name]!), after[name]!);
      if (i == 0 && defect == Defect.journalRemovedEarly) await _remove(record);
    }
    if (await record.exists()) await _remove(record);
  }

  /// Finishes every record left behind; one that cannot be read right now
  /// waits for the next access.
  Future<void> access() async {
    final folder = Directory(_journal);
    if (!await folder.exists()) return;
    await for (final entry in folder.list()) {
      if (entry is File && entry.path.endsWith('.json')) await _finish(entry);
    }
  }

  Future<void> _finish(File record) async {
    final json = jsonDecode(await record.readAsString()) as Map;
    for (final name in _participants) {
      final entry = json[name] as Map;
      final after = entry['after'] as String;
      final seen = await observeFile(_path(name));
      final bytes = seen.bytes;
      if (seen.status == 2 || seen.status == 3) {
        if (defect != Defect.quarantineOnEio) return;
        await quarantine(Directory(profile.support), record, 'unreadable');
        return;
      }
      if (bytes == null) {
        await quarantine(Directory(profile.support), record, 'gone');
        return;
      }
      if (_sha(bytes) == _sha(utf8.encode(after))) continue;
      if (_sha(bytes) != entry['before']) {
        await quarantine(Directory(profile.support), record, 'changed');
        return;
      }
      await _replace(name, bytes, after);
    }
    await _remove(record);
  }

  /// The text of [name] after recovery, or `unreadable`; never blocked by a
  /// record recovery could not finish.
  Future<String> read(String name) async {
    try {
      await access();
    } on FileSystemException {
      // Reads go on.
    }
    return await _read(name) ?? 'unreadable';
  }

  Future<String?> _read(String name) async {
    final seen = await observeFile(_path(name));
    return seen.status == 0 ? utf8.decode(seen.bytes!) : null;
  }

  Future<void> _replace(String name, List<int> before, String after) async {
    final kept = p.join(_kept, '${_sha(before).substring(0, 8)}.pgn');
    if (!await File(kept).exists()) await _publish(kept, before);
    final path = _path(name);
    final bytes = utf8.encode(after);
    switch (defect) {
      case Defect.inPlaceWrite:
        await File(path).writeAsBytes(bytes);
        await syncFile(path);
      case Defect.publishBeforeSync:
        await _stage(path, bytes);
        await replaceFileContents(temporaryPathFor(path), path);
        await syncFile(path);
        await syncDirectory(_folder);
      default:
        await _publish(path, bytes);
    }
  }

  Future<void> _publish(String path, List<int> bytes) async {
    await _stage(path, bytes);
    await syncFile(temporaryPathFor(path));
    await replaceFileContents(temporaryPathFor(path), path);
    await syncDirectory(p.dirname(path));
  }

  Future<void> _stage(String path, List<int> bytes) async {
    final staged = await File(
      temporaryPathFor(path),
    ).open(mode: FileMode.write);
    try {
      await staged.writeFrom(bytes);
    } finally {
      await staged.close();
    }
  }

  Future<void> _remove(File record) async {
    await record.delete();
    await syncDirectory(_journal);
  }

  Future<void> _writeDerived() async {
    try {
      await File(derived).writeAsString('${_participants.length} files');
    } on FileSystemException {
      if (defect == Defect.derivedFailureFails) rethrow;
      // Derived: the next run writes it again.
    }
  }
}

final _profiles = <Profile>[];

Future<Profile> _seeded() async {
  final profile = await Profile.temporary();
  _profiles.add(profile);
  for (final folder in [
    'Documents/toy/.cap-generation/i/v2-1',
    'Support/compound-writes',
    'Support/backups/toy',
  ]) {
    await Directory(p.join(profile.root, folder)).create(recursive: true);
  }
  for (final MapEntry(:key, :value) in _texts.entries) {
    await File(profile.document('toy/$key')).writeAsString(value);
  }
  return profile;
}

Future<DiskRun<T>> _run<T>(
  Profile profile,
  FaultPlan plan,
  Future<T> Function() body,
) => FaultyDisk(Directory(profile.root)).run(plan, body);

/// What the toy's command does with no fault, and the states either side.
final class _Recording {
  _Recording(this.trace, this.verdict, this.before, this.after);
  final List<IoOp> trace;
  final Verdict verdict;
  final ProfileSnapshot before;
  final ProfileSnapshot after;

  late final beforeIntegrity = ProfileIntegrity.of(before);
  late final afterIntegrity = ProfileIntegrity.of(after);

  Iterable<IoOp> get mutating => trace.where((op) => !op.kind.reads);

  Object? answer(ProfileSnapshot state, String name) =>
      state.text('Documents/toy/$name');
}

Future<_Recording> _record(Defect defect) async {
  final profile = await _seeded();
  final before = ProfileSnapshot.of(profile);
  final run = await _run(profile, const FaultPlan.none(), () {
    return Toy(profile, defect).commit();
  });
  final verdict = (run.end as Returned<Verdict>).value;
  return _Recording(run.trace, verdict, before, ProfileSnapshot.of(profile));
}

List<Violation> _lints(_Recording recording) => [
  ...syncedBeforePublish(recording.trace),
  ...directoriesSynced(
    recording.trace,
    committed: recording.verdict == Verdict.committed,
  ),
  ...journalFirst(recording.trace),
  ...noInPlaceWrites(recording.trace),
  ...noReadBack(recording.trace),
  ...verdictsHold(
    before: recording.before,
    after: recording.after,
    results: [('record', recording.verdict, recording.after)],
  ),
];

/// A crash before and after each effect, then a restart: the first read,
/// a probe of the untouched file, and a second access.
Future<List<Violation>> _crashes(Defect defect, _Recording recording) async {
  final violations = <Violation>[];
  final reopenedAt = <(String, ProfileSnapshot)>[];
  for (final op in recording.mutating) {
    for (final fault in const [CrashBefore(), CrashAfter()]) {
      final at = 'crash/${fault.runtimeType}/${op.key}';
      final profile = await _seeded();
      await _run(profile, FaultPlan.at(op.key, fault), () {
        return Toy(profile, defect).commit();
      });
      final toy = Toy(profile, defect);
      final read = await _run(profile, const FaultPlan.none(), () async {
        return (await toy.read('a.pgn'), await toy.read('c.pgn'));
      });
      final (first, probe) = (read.end as Returned<(String, String)>).value;
      final reopened = ProfileSnapshot.of(profile);
      await _run(profile, const FaultPlan.none(), toy.access);
      reopenedAt.add((at, reopened));
      violations.addAll(
        _afterCrash(at, recording, reopened, ProfileSnapshot.of(profile), (
          first,
          probe,
        )),
      );
    }
  }
  return [
    ...violations,
    ...verdictsHold(
      before: recording.before,
      after: recording.after,
      crashes: reopenedAt,
    ),
  ];
}

List<Violation> _afterCrash(
  String at,
  _Recording recording,
  ProfileSnapshot reopened,
  ProfileSnapshot second,
  (String, String) answers,
) {
  final (before, after) = (recording.before, recording.after);
  return [
    ...recoverableBoundary(
      at: at,
      before: before,
      after: after,
      reopened: reopened,
    ),
    ...recoveredOnAccess(at: at, first: reopened, second: second),
    ...quarantineHasCause(at: at, start: before, end: second),
    ...neverLocked(
      at: at,
      before: {'c': recording.answer(before, 'c.pgn')},
      after: {'c': recording.answer(after, 'c.pgn')},
      reopened: {'c': answers.$2},
    ),
    ...nothingDeleted(
      at: at,
      before: recording.beforeIntegrity,
      after: recording.afterIntegrity,
      reopened: ProfileIntegrity.of(reopened),
    ),
    ...recoveredBeforeRead(
      at: at,
      before: recording.answer(before, 'a.pgn'),
      after: recording.answer(after, 'a.pgn'),
      reopened: answers.$1,
    ),
  ];
}

/// An I/O error at each effect, once; then the same session's next access.
Future<List<Violation>> _transients(Defect defect, _Recording recording) async {
  final violations = <Violation>[];
  for (final op in recording.trace) {
    final at = 'transient/${op.key}';
    final profile = await _seeded();
    final toy = Toy(profile, defect);
    final run = await _run(
      profile,
      FaultPlan.at(op.key, const FailBefore(IoError.eio)),
      () async {
        final verdict = await toy.commit();
        await toy.access();
        return verdict;
      },
    );
    final state = ProfileSnapshot.of(profile);
    violations
      ..addAll(transientDeferred(at: at, afterClear: state))
      ..addAll(quarantineHasCause(at: at, start: recording.before, end: state))
      ..addAll(
        verdictsHold(
          before: recording.before,
          after: recording.after,
          results: [(at, (run.end as Returned<Verdict>).value, state)],
        ),
      );
  }
  return violations;
}

/// The answer to each effect lost once; then a retry of the same request.
Future<List<Violation>> _lostAcks(Defect defect, _Recording recording) async {
  final violations = <Violation>[];
  for (final op in recording.mutating) {
    final at = 'lostAck/${op.key}';
    final profile = await _seeded();
    final toy = Toy(profile, defect);
    final run = await _run(
      profile,
      FaultPlan.at(op.key, const FailAfter(IoError.eio)),
      () async {
        await toy.commit();
        return toy.commit();
      },
    );
    final state = ProfileSnapshot.of(profile);
    violations
      ..addAll(
        retryIdempotent(
          at: at,
          retried: (run.end as Returned<Verdict>).value,
          after: recording.after,
          state: state,
        ),
      )
      ..addAll(quarantineHasCause(at: at, start: recording.before, end: state));
  }
  return violations;
}

/// An I/O error at each effect of the recovery a crash leaves pending, for
/// the first and the last such crash; then the next access.
Future<List<Violation>> _recoveryFaults(
  Defect defect,
  _Recording recording,
) async {
  final pending = <OpKey>[];
  for (final op in recording.mutating) {
    final profile = await _seeded();
    await _crashAt(profile, defect, op.key);
    if (ProfileSnapshot.of(profile).pending.isNotEmpty) pending.add(op.key);
  }
  final violations = <Violation>[];
  for (final crash in {pending.first, pending.last}) {
    final profile = await _seeded();
    await _crashAt(profile, defect, crash);
    final recovery = await _run(profile, const FaultPlan.none(), () {
      return Toy(profile, defect).access();
    });
    for (final op in recovery.trace) {
      final at = 'recoveryFault/$crash/${op.key}';
      final replay = await _seeded();
      await _crashAt(replay, defect, crash);
      final start = ProfileSnapshot.of(replay);
      final toy = Toy(replay, defect);
      await _run(
        replay,
        FaultPlan.at(op.key, const FailBefore(IoError.eio)),
        () async {
          await toy.access().then((_) {}, onError: (Object _) {});
          await toy.access();
        },
      );
      final state = ProfileSnapshot.of(replay);
      violations
        ..addAll(quarantineHasCause(at: at, start: start, end: state))
        ..addAll(transientDeferred(at: at, afterClear: state));
    }
  }
  return violations;
}

Future<void> _crashAt(Profile profile, Defect defect, OpKey key) =>
    _run(profile, FaultPlan.at(key, const CrashAfter()), () {
      return Toy(profile, defect).commit();
    });

/// A failed write of the derived index, then the next run.
Future<List<Violation>> _derivedFault(Defect defect) async {
  final profile = await _seeded();
  final toy = Toy(profile, defect);
  final run = await _run(
    profile,
    FaultPlan.where(
      (op) => !op.kind.reads && classifyAny(op.key.path) == Authority.derived,
      const FailBefore(IoError.eio),
    ),
    () async => (await toy.commit(), await toy.commit()),
  );
  final (verdict, _) = (run.end as Returned<(Verdict, Verdict)>).value;
  return derivedNeverBlocks(
    at: 'derived/${p.basename(toy.derived)}',
    verdict: verdict,
    rewritten: File(toy.derived).existsSync(),
  );
}

Future<List<Violation>> _everything(Defect defect) async {
  final recording = await _record(defect);
  return [
    ..._lints(recording),
    ...await _crashes(defect, recording),
    ...await _transients(defect, recording),
    ...await _lostAcks(defect, recording),
    ...await _recoveryFaults(defect, recording),
    ...await _derivedFault(defect),
  ];
}

const _flaggedBy = {
  Defect.none: <String>{},
  Defect.inPlaceWrite: {'R4'},
  Defect.publishBeforeSync: {'R1'},
  Defect.journalRemovedEarly: {'O1'},
  Defect.quarantineOnEio: {'O4'},
  Defect.duplicateOnRetry: {'O8'},
  Defect.derivedFailureFails: {'O10'},
};

void main() {
  tearDownAll(() async {
    for (final profile in _profiles) {
      await profile.dispose();
    }
  });

  group('the toy store', () {
    for (final MapEntry(key: defect, value: contracts) in _flaggedBy.entries) {
      test(
        defect == Defect.none
            ? 'passes every contract when it is correct'
            : 'with ${defect.name} is flagged by ${contracts.single} alone',
        () async {
          final violations = await _everything(defect);
          expect(
            {for (final v in violations) v.contract},
            contracts,
            reason: violations.take(10).join('\n'),
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }
  });

  group('the Authority table', () {
    test('throws for a path no row names', () {
      expect(() => classify('Support/mystery.bin'), throwsArgumentError);
      expect(() => classify('Elsewhere/a.pgn'), throwsArgumentError);
      expect(
        classify('Documents/repertoires/KID', directory: true),
        Authority.authoritative,
      );
      expect(
        classify('Documents/repertoires/.KID.pgn.v2-tmp'),
        Authority.staging,
      );
      expect(classify('Support/finds.db'), Authority.derived);
      expect(classify('Support/app_games.db'), Authority.authoritative);
    });

    test(
      'names every path of the standard profile, a section rename and a move',
      () async {
        final run = await _standardRun();
        for (final state in [run.before, run.after]) {
          state.entries.keys.forEach(state.classOf);
        }
        for (final op in [...run.rename, ...run.move]) {
          classifyAny(op.key.path);
          if (op.key.to case final to?) classifyAny(to);
        }
        expect(run.untraced, isEmpty);
      },
    );
  });

  test('the standard profile\'s references resolve, and a section rename '
      'and a move keep them and every game', () async {
    final run = await _standardRun();
    final before = ProfileIntegrity.of(run.before);
    final after = ProfileIntegrity.of(run.after);
    // The row seeded for a chapter that was gone before anything ran.
    expect(
      before.orphanKeys.single,
      startsWith('$reviewsFile: ${run.profile.repertoires}/Gone/'),
    );
    expect(before.unresolvedSelectors, isEmpty);
    // The chapter seeding deleted: its row and selector followed it aside,
    // and still resolve there.
    expect(
      run.before.text('Support/books.json'),
      contains(p.posix.relative(kidDeletedAside, from: 'repertoires')),
    );
    expect(
      run.before.text('Documents/$streaksFile'),
      contains(run.profile.document(kidDeletedAside)),
    );
    expect(after.orphanKeys, before.orphanKeys);
    expect(after.unresolvedSelectors, isEmpty);
    expect(
      nothingDeleted(
        at: 'standard',
        before: before,
        after: after,
        reopened: after,
      ),
      isEmpty,
    );
  });

  group('the save discipline lints on real traces', () {
    test('hold for a section rename and a move', () async {
      final run = await _standardRun();
      for (final (trace, start) in [
        (run.rename, run.before),
        (run.move, run.between),
      ]) {
        final existing = start.entries.keys.toSet();
        expect([
          ...syncedBeforePublish(trace),
          ...journalFirst(trace, existing: existing),
          ...noInPlaceWrites(trace),
          ...noReadBack(trace),
        ], isEmpty);
      }
      expect(
        directoriesSynced(
          run.move,
          committed: true,
          existing: run.between.entries.keys.toSet(),
        ),
        isEmpty,
      );
    });

    test('R2 holds for the first kept version of a document', () async {
      final run = await _standardRun();
      expect(
        directoriesSynced(
          run.rename,
          committed: true,
          existing: run.before.entries.keys.toSet(),
        ),
        isEmpty,
      );
    });
  });
}

/// The standard profile, then a section rename and a move through the real
/// store, each with its trace.
final class _StandardRun {
  const _StandardRun({
    required this.profile,
    required this.before,
    required this.between,
    required this.after,
    required this.rename,
    required this.move,
    required this.untraced,
  });
  final Profile profile;
  final ProfileSnapshot before;

  /// After the rename, before the move.
  final ProfileSnapshot between;
  final ProfileSnapshot after;
  final List<IoOp> rename;
  final List<IoOp> move;

  /// Changes no traced effect explains: a write around the seam.
  final List<String> untraced;
}

Future<_StandardRun> _standardRun() async {
  final profile = await Profile.temporary();
  _profiles.add(profile);
  await seedStandardProfile(profile);
  final before = ProfileSnapshot.of(profile);
  final disk = FaultyDisk(Directory(profile.root));
  final plainBefore = disk.snapshot();
  final rename = await disk.run(const FaultPlan.none(), () {
    return _renameSection(_store(profile), profile);
  });
  final between = ProfileSnapshot.of(profile);
  final move = await disk.run(const FaultPlan.none(), () {
    return _moveChapter(_store(profile), profile);
  });
  expect((rename.end as Returned<SaveResult>).value, isA<Saved>());
  expect((move.end as Returned<MoveResult>).value, isA<Moved>());
  return _StandardRun(
    profile: profile,
    before: before,
    between: between,
    after: ProfileSnapshot.of(profile),
    rename: rename.trace,
    move: move.trace,
    untraced: untracedWrites(plainBefore, disk.snapshot(), [
      ...rename.trace,
      ...move.trace,
    ], unmanaged: sqliteManaged),
  );
}

PgnFileStore _store(Profile profile) => PgnFileStore(
  documents: Directory(profile.documents),
  support: Directory(profile.support),
  recoveryRetry: Duration.zero,
);

/// Renames the course's first section, which its book selector follows.
Future<SaveResult> _renameSection(PgnFileStore store, Profile profile) async {
  final ref = DocumentRef(profile.document(kidCourse));
  final text = await File(ref.path).readAsString();
  final from = kidCourseSections.first;
  return store.save(
    ref,
    text.replaceAll('[ChapterName "$from"]', '[ChapterName "Classical"]'),
    expected: await _revision(ref),
    scope: GamesEdited(
      GamesWritten(rewritten: const {0, 1}),
      references: ReferenceChanges([
        SectionRename(path: ref.path, from: from, to: 'Classical'),
      ]),
    ),
  );
}

/// Moves a trained chapter into another repertoire.
Future<MoveResult> _moveChapter(PgnFileStore store, Profile profile) async {
  final ref = DocumentRef(profile.document(benkoAccepted));
  return store.move(
    ref,
    DocumentRef(profile.document('repertoires/KID/Benko accepted.pgn')),
    expected: await _revision(ref),
    operationId: 'move-1',
  );
}

Future<Revision> _revision(DocumentRef ref) async =>
    (await probeDocument(ref.path) as FileFound).revision;
