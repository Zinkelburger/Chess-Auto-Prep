/// An operation has two kinds of participant. Pivots have exact before and
/// after states, such as a file or folder at one of two names; they are
/// applied first, and until they are the operation guards them. References
/// point at the pivots (training rows, book selectors, kept versions) and
/// follow them once every pivot has landed: as planned while they still hold
/// what was planned, planned again from what they hold now otherwise. So only
/// a pivot can make an operation impossible.
library;

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
      switch (await pivotsLanded(parts, looks, looks.indexOf(look))) {
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
Future<Holds> pivotsLanded(
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
