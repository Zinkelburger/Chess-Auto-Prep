/// Every change the store makes to more than one file is written down first,
/// carried out, then forgotten: `Support/<journal>/<id>.json`. This is where
/// a record is carried from written down to gone; its format stays its
/// owner's.
///
/// An operation has two kinds of participant. Pivots have exact before and
/// after states, such as a file or folder at one of two names; they are
/// applied first, and until they are the operation guards them. References
/// point at the pivots (training rows, book selectors, kept versions) and
/// follow them once every pivot has landed: as planned while they still hold
/// what was planned, planned again from what they hold now otherwise. So only
/// a pivot can make an operation impossible.
///
/// A recorded operation ends one of three ways. [Finished]. [Deferred]:
/// something passing stopped it, and the record is kept, tried again and
/// owed in the [RecoveryLedger]. [SetAside]: a pivot holds another writer's
/// bytes, so the pivots this attempt applied are put back, and the record is
/// marked set aside ([asideMarker]) and moved whole into
/// `recovery-quarantine/`. [Refused] means nothing was written.
library;

import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'journal_records.dart';
import 'recovery_files.dart';
import 'recovery_ledger.dart';

/// What a participant holds now, measured against its operation's plan.
sealed class Holds {
  const Holds();
}

final class HoldsBefore extends Holds {
  const HoldsBefore();
}

final class HoldsAfter extends Holds {
  const HoldsAfter();
}

/// Another writer's bytes, a link, another file at the name: the plan can
/// never be applied over it.
final class HoldsOther extends Holds {
  const HoldsOther(this.detail);
  final String detail;
}

/// It could not be read reliably just now; nothing is decided on it.
final class CannotTell extends Holds {
  const CannotTell(this.detail, {this.unapplied = false});
  final String detail;

  /// Whether it is known not to have been applied, only what it holds could
  /// not be read: a folder still at its old name with a file in it held
  /// open. An operation that stops guarding it has nothing to put back.
  final bool unapplied;
}

/// A participant with exact before and after states, applied before any
/// reference and guarded until it is.
abstract interface class Pivot {
  /// The canonical files and folders it changes; a folder covers what it
  /// holds.
  Set<String> get paths;

  Future<Holds> look();

  /// Before to after. Throws [PivotTaken] when the disk refuses for good;
  /// any other throw is passing.
  Future<void> apply();

  /// Makes the after state durable, whichever attempt applied it.
  Future<void> settle();

  /// After to before, only while it holds exactly its after state; false
  /// when it holds anything else.
  Future<bool> putBack();
}

/// The disk refused a pivot for good: its name was taken meanwhile.
final class PivotTaken implements Exception {
  const PivotTaken(this.detail);
  final String detail;

  @override
  String toString() => detail;
}

/// Points at the pivots and follows them. Never guarded, never put back.
abstract interface class Reference {
  /// Exactly its planned before ([HoldsBefore]), its planned after, or
  /// something else ([HoldsOther]). Admission needs the first; a finish only
  /// needs it readable, since [follow] plans again from what is there.
  Future<Holds> look();

  /// Throws when it cannot be read or written just now, and [NotFollowed]
  /// when it can never follow.
  Future<void> follow();
}

/// A reference left as it was for good: the whole file is not its format,
/// or no plan for what it holds now can be read back from the record. The
/// operation still finishes, and its record is kept in quarantine, not
/// deleted, so what it planned can be had back.
final class NotFollowed implements Exception {
  const NotFollowed(this.detail);
  final String detail;

  @override
  String toString() => detail;
}

typedef Participants = ({List<Pivot> pivots, List<Reference> references});

sealed class Settlement {
  const Settlement();
}

final class Finished extends Settlement {
  const Finished({this.notFollowed = const []});

  /// Why each reference that could never follow was left as it was
  /// ([NotFollowed]); the record is then set aside, not deleted.
  final List<String> notFollowed;
}

/// Something passing stopped it in [phase]; the record is kept.
final class Deferred extends Settlement {
  const Deferred(this.detail, {required this.phase});
  final String detail;
  final Phase phase;
}

/// It can never finish, as far as [phase]; its record is in quarantine.
final class SetAside extends Settlement {
  const SetAside(this.detail, {required this.phase});
  final String detail;
  final Phase phase;
}

/// Nothing was written.
final class Refused extends Settlement {
  const Refused(this.reason);
  final Refusal reason;
}

sealed class Refusal {
  const Refusal();
  String get detail;
}

/// A participant is not what the operation was planned from.
final class Stale extends Refusal {
  const Stale(this.detail);
  @override
  final String detail;
}

/// The id names another change.
final class IdInUse extends Refusal {
  const IdInUse();
  @override
  String get detail => 'This operation id belongs to another change.';
}

/// The record could not be written, or something before it failed.
final class NotWritten extends Refusal {
  const NotWritten(this.detail);
  @override
  final String detail;
}

/// The part of a record the journal reads; the rest is its owner's format.
abstract interface class Recorded {
  String get id;

  /// False for a record an earlier build kept after it finished or gave up:
  /// it is removed, never carried out.
  bool get live;

  /// The record as its owner writes it.
  Map<String, Object?> get json;
}

/// Carries [parts] as far as the disk lets it. It looks at everything
/// first, so nothing is applied while any participant cannot be read: a
/// pivot that cannot be told, or a reference that cannot be read, defers
/// it, and a pivot holding something else sets it aside. Then it runs
/// [prepare], applies the pivots still before, settles them all and
/// follows the references; one that can never follow ([NotFollowed]) is
/// left as it is and named in [Finished.notFollowed]. A [PivotTaken] or a
/// [RecoveryRequired] from any step sets it aside. Setting aside while no
/// reference has followed yet puts back every pivot that holds what the
/// operation put there, whichever attempt applied it, so it is undone
/// whole; any other throw defers it.
///
/// [following] is for an operation that stopped guarding its pivots once
/// they had all landed ([followingMarker]): the user may have saved over
/// them since, so the pivots are neither looked at nor flushed here, and
/// only the references follow.
Future<Settlement> finishParticipants(
  Participants parts, {
  Future<void> Function()? prepare,
  String Function(Object error) describe = describeFailure,
  bool following = false,
}) async {
  var phase = following ? Phase.references : Phase.pivots;
  // The pivots holding what the operation put there, in order.
  final applied = <Pivot>[];
  try {
    final looks = [
      if (!following)
        for (final pivot in parts.pivots) await pivot.look(),
    ];
    if (looks.whereType<CannotTell>().firstOrNull case final look?) {
      return Deferred(look.detail, phase: phase);
    }
    for (final (i, look) in looks.indexed) {
      if (look is HoldsAfter) applied.add(parts.pivots[i]);
    }
    if (looks.whereType<HoldsOther>().firstOrNull case final look?) {
      switch (await _pivotsLanded(parts, looks, looks.indexOf(look))) {
        case CannotTell(:final detail):
          return Deferred(detail, phase: phase);
        case HoldsAfter():
          phase = Phase.references;
        case _:
      }
      return await _setAside(applied, look.detail, phase, describe);
    }
    if (looks.every((look) => look is HoldsAfter)) phase = Phase.references;
    for (final reference in parts.references) {
      // What a reference holds now only says how it will follow.
      if (await reference.look() case CannotTell(:final detail)) {
        return Deferred(detail, phase: phase);
      }
    }
    await prepare?.call();
    for (var i = 0; i < looks.length; i++) {
      if (looks[i] is! HoldsBefore) continue;
      await parts.pivots[i].apply();
      applied.add(parts.pivots[i]);
    }
    phase = Phase.references;
    if (!following) {
      for (final pivot in parts.pivots) {
        await pivot.settle();
      }
    }
    final notFollowed = <String>[];
    for (final reference in parts.references) {
      try {
        await reference.follow();
      } on NotFollowed catch (error) {
        notFollowed.add(error.detail);
      }
    }
    return Finished(notFollowed: notFollowed);
  } on RecoveryRequired catch (error) {
    return _setAside(applied, error.detail, phase, describe);
  } on PivotTaken catch (error) {
    return _setAside(applied, error.detail, phase, describe);
  } on Object catch (error) {
    return Deferred(describe(error), phase: phase);
  }
}

/// Whether every pivot of [parts] had landed before the one at [other]
/// was changed, or while it cannot be told ([HoldsAfter]), and so nothing
/// may be put back; [CannotTell] when that cannot be read now. Pivots land
/// in order and references only once they all have, so a later pivot
/// holding its after state, or a reference that has followed, says so.
/// Nothing is looked at when no pivot holds its after state, the one at
/// [other] included: there is nothing to put back.
Future<Holds> _pivotsLanded(
  Participants parts,
  List<Holds> looks,
  int other,
) async {
  if (looks[other] is! CannotTell && !looks.any((look) => look is HoldsAfter)) {
    return const HoldsBefore();
  }
  if (looks.skip(other + 1).any((look) => look is HoldsAfter)) {
    return const HoldsAfter();
  }
  for (final reference in parts.references) {
    final look = await reference.look();
    if (look is HoldsAfter || look is CannotTell) return look;
  }
  return const HoldsBefore();
}

/// Sets an operation aside, first putting back, last first, the [applied]
/// pivots that still hold exactly what it put there, while it is still in
/// its pivots: once a reference may have followed, nothing is undone. A
/// put-back that fails for now defers it instead, and the next attempt
/// decides again from the disk.
Future<Settlement> _setAside(
  List<Pivot> applied,
  String detail,
  Phase phase,
  String Function(Object error) describe,
) async {
  if (phase == Phase.pivots) {
    try {
      for (final pivot in applied.reversed) {
        await pivot.putBack();
      }
    } on Object catch (error) {
      return Deferred(describe(error), phase: phase);
    }
  }
  return SetAside(detail, phase: phase);
}

/// Why [error] stopped an operation, for the log and the caller.
String describeFailure(Object error) => switch (error) {
  RecoveryRequired(:final detail) => detail,
  _ => '$error',
};

/// The records one owner keeps under `Support/<name>/`, and the operations
/// they describe carried from written down to gone. The caller holds the
/// operation's locks for every call.
final class OperationJournal<R extends Recorded> {
  OperationJournal({
    required this.name,
    required Directory support,
    required this.decode,
    required this.participants,
    required this.steps,
    this.prepare,
    this.finished,
    this.handOver,
    this.lock,
    this.describe = describeFailure,
    this.testHook,
    this._clock = DateTime.now,
    this._synchronize = syncDirectory,
  }) : support = canonicalRecoveryRoot(support),
       ledger = RecoveryLedger.of(support) {
    // Preparing can create Support before the record is written; keep its
    // original containing ancestor through every retry.
    _metadataBoundary = recoveryMetadataBoundary(this.support);
  }

  /// The folder under Support the records are written in.
  final String name;
  final Directory support;
  final RecoveryLedger ledger;

  /// The owner's decoder, validation included; throws on a record it cannot
  /// carry out.
  final R Function(Object? json, String id) decode;

  /// [following] when the operation stopped guarding its pivots
  /// ([stopGuarding]) and only its references follow.
  final Participants Function(R record, {bool following}) participants;

  /// The owner's test steps: before the record, once it is written, and once
  /// it is gone.
  final ({Enum prepared, Enum intent, Enum completed}) steps;

  /// Keeps what must exist before anything changes. Runs before the record
  /// is written and again before each finish applies a pivot.
  final Future<void> Function(R record)? prepare;

  /// Told of each operation once it has finished, before its record goes.
  final void Function(R record)? finished;

  /// Runs before an operation whose pivots have landed stops guarding them
  /// ([stopGuarding]): hands to their own owner the references a save over
  /// the pivots would mislead. Throws to keep guarding.
  final Future<void> Function(R record)? handOver;

  /// Takes the locks [record]'s participants need around [action], as the
  /// command that recorded it took them; throws when it cannot.
  final Future<T> Function<T>(R record, Future<T> Function() action)? lock;
  final String Function(Object error) describe;
  final Future<void> Function(Enum step)? testHook;
  final DateTime Function() _clock;
  final Future<void> Function(String) _synchronize;
  late final String _metadataBoundary;

  Directory get _folder => Directory(p.join(support.path, name));
  File _file(String id) => File(p.join(_folder.path, '$id.json'));

  /// What [id] names: an operation this process finished, or one still
  /// recorded; null when neither.
  Future<({R record, bool done})?> named(String id) async {
    if (ledger.receipt<R>(name, id) case final done?) {
      return (record: done, done: true);
    }
    for (final (file, record) in await _readAll()) {
      if (record.id != id || !record.live) continue;
      if (await _movedAside(file, id)) return null;
      return (record: record, done: false);
    }
    return null;
  }

  /// Admits [record] only while every participant is exactly as planned,
  /// writes it down and carries it out. The caller asked [named] first.
  Future<Settlement> run(R record) async {
    try {
      if (await _admit(record) case final refusal?) return Refused(refusal);
      await recoveryDirectory(support, create: true);
      await recoveryDirectory(_folder, create: true);
      // New profile and journal ancestry must survive loss of this process.
      await flushRecoveryAncestry(
        _folder.path,
        through: _metadataBoundary,
        synchronize: _synchronize,
      );
      await testHook?.call(steps.prepared);
      await prepare?.call(record);
      final path = _file(record.id).path;
      await discardLeftoverStage(path);
      await createFileExclusively(path, encodeJournal(record.json));
    } on Object catch (error) {
      // A record in place is this operation's: [named] found none before,
      // unless it is one set aside that could not be moved yet.
      final file = _file(record.id);
      if (!file.existsSync() || asideMarker(file).existsSync()) {
        return Refused(NotWritten(describe(error)));
      }
      return _settle(record, Deferred(describe(error), phase: Phase.pivots));
    }
    return _finishAfter(steps.intent, record, setAside: false);
  }

  /// Why [record] may not start, if it may not: a participant that is not
  /// exactly as planned.
  Future<Refusal?> _admit(R record) async {
    final parts = participants(record);
    for (final look in [
      for (final pivot in parts.pivots) pivot.look,
      for (final reference in parts.references) reference.look,
    ]) {
      switch (await look()) {
        case HoldsBefore():
          continue;
        case HoldsOther(:final detail) || CannotTell(:final detail):
          return Stale(detail);
        case HoldsAfter():
          return const Stale('A participant changed while it was planned.');
      }
    }
    return null;
  }

  /// Carries out [record], which is recorded, now. The command that asked
  /// for it never sets it aside ([setAside] false): what stopped it may be
  /// its own passing failure, so the record waits for the next pass.
  Future<Settlement> finish(R record, {bool setAside = true}) =>
      _finishAfter(null, record, setAside: setAside);

  Future<Settlement> _finishAfter(
    Enum? step,
    R record, {
    required bool setAside,
  }) async {
    final Settlement settlement;
    try {
      if (step != null) await testHook?.call(step);
      final following = followingMarker(_file(record.id)).existsSync();
      settlement = await finishParticipants(
        participants(record, following: following),
        prepare: prepare == null ? null : () => prepare!(record),
        describe: describe,
        following: following,
      );
    } on Object catch (error) {
      return _settle(record, Deferred(describe(error), phase: Phase.pivots));
    }
    if (settlement case SetAside(:final detail, :final phase) when !setAside) {
      return _settle(record, Deferred(detail, phase: phase));
    }
    return _settle(record, settlement);
  }

  Future<Settlement> _settle(R record, Settlement settlement) async {
    final file = _file(record.id);
    switch (settlement) {
      case Finished(:final notFollowed):
        try {
          ledger.remember(name, record.id, record);
          finished?.call(record);
          if (notFollowed.isEmpty) {
            await forgetRecord(file, synchronize: _synchronize);
            ledger.settled(name, record.id);
          } else {
            // Done, but what could not follow is only in the record.
            await _markAside(file);
            await _moveAside(
              file,
              record.id,
              RecoveryRequired('Not followed: ${notFollowed.join(' ')}'),
              phase: Phase.references,
            );
          }
          await testHook?.call(steps.completed);
        } on Object catch (error) {
          return _settle(
            record,
            Deferred(describe(error), phase: Phase.references),
          );
        }
      case Deferred(:final detail, :final phase):
        if (!file.existsSync()) break;
        ledger.deferred(
          name,
          record.id,
          // One set aside guards nothing, whatever still keeps its record.
          paths: asideMarker(file).existsSync()
              ? const {}
              : {
                  for (final pivot in participants(record).pivots)
                    ...pivot.paths,
                },
          detail: detail,
          phase: phase,
          now: _clock(),
        );
        // A marker an earlier process wrote says the same as its ledger did.
        if (followingMarker(file).existsSync()) {
          ledger.savesMayPass(name, record.id);
        }
      case SetAside(:final detail, :final phase):
        try {
          await _markAside(file);
        } on Object catch (error) {
          return _settle(record, Deferred(describe(error), phase: phase));
        }
        await _moveAside(
          file,
          record.id,
          RecoveryRequired(detail),
          phase: phase,
        );
      case Refused():
        break;
    }
    return settlement;
  }

  /// Takes over the recorded operation [same] knows as the change a caller
  /// asks for again under the new [id], having lost the first: it is
  /// finished now and answered as the caller's own, under [id] too once it
  /// has finished. Null when none is recorded.
  Future<(R, Settlement)?> adopt(
    String id,
    bool Function(R record) same,
  ) async {
    for (final (file, record) in await _readAll()) {
      if (!record.live || !same(record)) continue;
      if (await _movedAside(file, record.id)) continue;
      final settlement = await finish(record, setAside: false);
      if (settlement is Finished) ledger.remember(name, id, record);
      return (record, settlement);
    }
    return null;
  }

  /// Stops the owed operation [id] guarding its pivots, once it has guarded
  /// them too long: the app must never stay locked on one operation. It
  /// runs under the operation's locks, as a finish does.
  ///
  /// While a pivot is still before, no reference has followed, so it is
  /// undone as a whole: the pivots it applied are put back where they still
  /// hold exactly what it put there, and the record is marked set aside
  /// ([asideMarker]) and moved into quarantine; nothing is put back when a
  /// pivot another writer changed was changed after the whole edit had
  /// landed, as a finish decides it. A pivot known not to be applied counts
  /// as before even when what it holds cannot be read. Once every pivot has
  /// landed it can only go forward: [handOver] runs, its marker
  /// ([followingMarker]) says a later finish follows the references alone,
  /// and plain saves over its pivots may pass, while operations over them
  /// still wait.
  ///
  /// A pivot that cannot be read is decided by the rest ([_pivotsLanded]):
  /// a later pivot that landed, or a reference that followed, says the whole
  /// edit had landed. Otherwise, when it is the last pivot, the others are
  /// put back and it is never written: at worst it keeps what the edit put
  /// there, beside what came before it restored. An earlier one may hold
  /// the edit's bytes while a later one does not, so then it alone stays
  /// guarded until a finish can read it and decide. Nothing changes while
  /// the references cannot be read either.
  Future<void> stopGuarding(String id) async {
    final owed = ledger.owing(name, id);
    final file = _file(id);
    if (owed == null || !file.existsSync()) return;
    // One set aside is only moved; it guards nothing.
    if (await _movedAside(file, id)) return;
    final recorded = await named(id);
    if (recorded == null || recorded.done) return;
    final record = recorded.record;
    final lock = this.lock;
    if (lock == null) return _stopGuarding(record, owed);
    return lock(record, () => _stopGuarding(record, owed));
  }

  Future<void> _stopGuarding(R record, Owed owed) async {
    final file = _file(record.id);
    if (!file.existsSync()) return;
    final parts = participants(record);
    final pivots = parts.pivots;
    final looks = [for (final pivot in pivots) await pivot.look()];
    // One whose whole edit landed before a pivot was changed, or while one
    // cannot be read, is not undone.
    var landed = looks.every((look) => look is HoldsAfter);
    if (looks.indexWhere(
          (look) =>
              look is HoldsOther || (look is CannotTell && !look.unapplied),
        )
        case final doubt when doubt >= 0) {
      switch (await _pivotsLanded(parts, looks, doubt)) {
        case CannotTell():
          return;
        case HoldsAfter():
          landed = true;
        case _:
      }
    }
    if (landed && !looks.any((look) => look is HoldsOther)) {
      final marker = followingMarker(file);
      if (!marker.existsSync()) {
        await handOver?.call(record);
        await createFileExclusively(
          marker.path,
          const [],
          synchronize: _synchronize,
        );
      }
      ledger.savesMayPass(name, record.id);
      log.w(
        'let saves pass $name/${record.id}, owed since ${owed.since}',
        owed.detail,
      );
      return;
    }
    final unread = [
      for (final (i, look) in looks.indexed)
        if (look is CannotTell && !look.unapplied) i,
    ];
    if (!landed && unread.any((i) => i < pivots.length - 1)) {
      // Undone around it, it could keep the edit's first half alone.
      ledger.deferred(
        name,
        record.id,
        paths: {for (final i in unread) ...pivots[i].paths},
        detail: owed.detail,
        phase: owed.phase,
        now: _clock(),
      );
      log.w(
        'guard only what cannot be read of $name/${record.id}, owed since '
        '${owed.since}',
        owed.detail,
      );
      return;
    }
    for (var i = pivots.length - 1; i >= 0 && !landed; i--) {
      if (looks[i] is HoldsAfter) await pivots[i].putBack();
    }
    await _markAside(file);
    await _moveAside(
      file,
      record.id,
      RecoveryRequired('Unfinished since ${owed.since}: ${owed.detail}'),
      phase: owed.phase,
    );
  }

  /// Marks [record] set aside ([asideMarker]) once whatever it undoes is
  /// put back, so it is never carried out again, even while it cannot be
  /// moved into quarantine. A throw leaves it owed as it was: until marked,
  /// it still guards its pivots, and the next attempt decides from the disk.
  Future<void> _markAside(File record) async {
    final marker = asideMarker(record);
    if (marker.existsSync()) return;
    await createFileExclusively(
      marker.path,
      const [],
      synchronize: _synchronize,
    );
  }

  /// Moves [record], marked set aside, into quarantine. One the disk will
  /// not let go of yet stays owed, guarding nothing, and only the move is
  /// tried again ([_movedAside]).
  Future<void> _moveAside(
    File record,
    String id,
    Object reason, {
    required Phase phase,
  }) async {
    if (await quarantineRecord(support, record, reason)) {
      ledger.settled(name, id);
      return;
    }
    ledger.deferred(
      name,
      id,
      paths: const {},
      detail: 'set aside; the record could not be moved',
      phase: phase,
      now: _clock(),
    );
  }

  /// Whether [record] was set aside ([asideMarker]): it is never carried
  /// out, and its move into quarantine is tried again now.
  Future<bool> _movedAside(File record, String id) async {
    if (!asideMarker(record).existsSync()) return false;
    await _moveAside(
      record,
      id,
      const RecoveryRequired('Set aside earlier.'),
      phase: ledger.owing(name, id)?.phase ?? Phase.pivots,
    );
    return true;
  }

  /// Finishes the recorded operations [overlaps] picks, so a new one never
  /// plans over one left unfinished. The first that fails for now stops
  /// the rest and is answered; one that can never finish is set aside.
  Future<Deferred?> finishOverlapping(bool Function(R record) overlaps) async {
    for (final (file, record) in await _readAll()) {
      if (!record.live || !overlaps(record)) continue;
      if (await _movedAside(file, record.id)) continue;
      if (await finish(record) case final Deferred deferred) return deferred;
    }
    return null;
  }

  /// Finishes the operations a stopped process or a failed command left,
  /// and tells the ledger what each came to. One that can never finish, or
  /// whose record is damaged, is set aside and logged; the rest still run.
  Future<void> recover() async {
    for (final (file, record) in await _readAll()) {
      if (!record.live) {
        await _forgetLeftover(file, record.id);
        continue;
      }
      if (await _movedAside(file, record.id)) continue;
      if (await _locked(record) case Deferred(:final detail)) {
        log.w('finish the operation recorded at ${file.path}', detail);
      }
    }
  }

  /// [finish] under the locks [lock] takes; one it cannot take defers it
  /// where it was.
  Future<Settlement> _locked(R record) async {
    final lock = this.lock;
    if (lock == null) return finish(record);
    try {
      return await lock<Settlement>(record, () => finish(record));
    } on Object catch (error) {
      final phase = ledger.owing(name, record.id)?.phase ?? Phase.pivots;
      return _settle(record, Deferred(describe(error), phase: phase));
    }
  }

  /// Removes a finished or abandoned record, which earlier builds kept too.
  /// One that cannot be removed yet is tried again but guards nothing.
  Future<void> _forgetLeftover(File record, String id) async {
    try {
      await forgetRecord(record, synchronize: _synchronize);
      ledger.settled(name, id);
    } on Object catch (error) {
      ledger.deferred(
        name,
        id,
        paths: const {},
        detail: describe(error),
        now: _clock(),
      );
      log.w('remove the finished record at ${record.path}', error);
    }
  }

  Future<List<(File, R)>> _readAll() async {
    if (!await recoveryDirectory(support)) return const [];
    return readJournal(_folder, decode: decode);
  }
}
