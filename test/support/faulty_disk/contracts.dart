// The data contracts of docs/ARCHITECTURE_RENEWAL.md ("Data correctness
// contracts", "Data safety") as checks over what a FaultyDisk run leaves:
// snapshots of the profile, what reading it answered, and the trace. Each
// returns the violations it finds, with the replay key that shows them,
// rather than failing a test, so one run reports all of them.
//
// O1-O10 look at outcomes. R1-R5 look at a trace for the save discipline a
// kill cannot show, since the page cache survives a kill: they state it as
// relations between effects, never as a sequence of calls.
import 'package:path/path.dart' as p;

import '../profile/authority.dart';
import '../profile/profile_integrity.dart';
import '../profile/profile_snapshot.dart';
import 'io_trace.dart';

/// What a command answered: its work is complete, nothing changed, or it
/// cannot tell (a lost acknowledgement: retry with the same operation).
enum Verdict { committed, rejected, unknown }

final class Violation {
  const Violation(this.contract, this.at, this.detail);

  /// `O1`-`O10`, [dataLost] or `R1`-`R5`.
  final String contract;

  /// Where it shows: a family and an effect's key, such as
  /// `crash/publishReplace:Documents/.a.pgn.v2-tmp->Documents/a.pgn#0`.
  final String at;
  final String detail;

  @override
  String toString() => '$contract at $at: $detail';
}

/// **O1, one recoverable boundary.** "Give a document change and its
/// reference changes one recoverable boundary"; "a crash between them is
/// finished on the next access". Once reopened after a crash, the system of
/// record is all of the command or none of it.
List<Violation> recoverableBoundary({
  required String at,
  required ProfileSnapshot before,
  required ProfileSnapshot after,
  required ProfileSnapshot reopened,
}) {
  final now = reopened.projection;
  if (_same(now, before.projection) || _same(now, after.projection)) {
    return const [];
  }
  return [
    Violation(
      'O1',
      at,
      'reopened as neither before nor after; against after:\n'
          '${projectionDiff(after.projection, now)}',
    ),
  ];
}

/// **O2, committed, rejected or unknown.** "Required application states are
/// committed, rejected (nothing changed) and unknown." Across [crashes], in
/// trace order, once a crash reopens as after no later one reopens as
/// before (states that are neither are O1's). A committed result is after;
/// a rejected one is before with no record pending. Unknown is O8's.
List<Violation> verdictsHold({
  required ProfileSnapshot before,
  required ProfileSnapshot after,
  List<(String at, ProfileSnapshot reopened)> crashes = const [],
  List<(String at, Verdict verdict, ProfileSnapshot state)> results = const [],
}) {
  final violations = <Violation>[];
  String? landed;
  for (final (at, reopened) in crashes) {
    final now = reopened.projection;
    if (_same(now, after.projection)) {
      landed ??= at;
    } else if (landed != null && _same(now, before.projection)) {
      violations.add(
        Violation('O2', at, 'undone, though a crash at $landed was not'),
      );
    }
  }
  for (final (at, verdict, state) in results) {
    final now = state.projection;
    if (verdict == Verdict.committed && !_same(now, after.projection)) {
      violations.add(
        Violation(
          'O2',
          at,
          'committed, but:\n${projectionDiff(after.projection, now)}',
        ),
      );
    }
    if (verdict == Verdict.rejected &&
        (!_same(now, before.projection) || state.pending.isNotEmpty)) {
      violations.add(
        Violation('O2', at, 'rejected, but something changed or waits'),
      );
    }
  }
  return violations;
}

/// **O3, recovery on the next access, once.** "Unfinished operations are
/// finished on the first access after a crash." No record is pending after
/// [first] access, and a [second] changes nothing the user owns or the
/// recovery keeps. A staged copy may wait for the next write in its folder,
/// and derived data and logs may change on any access.
List<Violation> recoveredOnAccess({
  required String at,
  required ProfileSnapshot first,
  required ProfileSnapshot second,
}) => [
  if (first.pending.isNotEmpty)
    Violation('O3', at, 'still pending after an access: ${first.pending}'),
  for (final name in second.changedFrom(first))
    if (!_changesOnAccess(name))
      Violation('O3', at, 'a second access changed $name'),
];

bool _changesOnAccess(String relative) => switch (classifyAny(relative)) {
  Authority.staging || Authority.derived || Authority.log => true,
  _ => false,
};

/// **O4, quarantine only with a cause.** "A participant that cannot be read
/// right now (held open, or changing while read) leaves the record pending";
/// only one changed by another program, or a record that cannot be read or
/// is of a newer version, is quarantined. Never after a plain crash or an
/// I/O error: without [cause], nothing new may appear in quarantine between
/// [start] and [end].
List<Violation> quarantineHasCause({
  required String at,
  required ProfileSnapshot start,
  required ProfileSnapshot end,
  bool cause = false,
}) {
  if (cause) return const [];
  final added = end.quarantine.toSet().difference(start.quarantine.toSet());
  return [
    if (added.isNotEmpty)
      Violation(
        'O4',
        at,
        'quarantined with no cause: ${added.toList()..sort()}',
      ),
  ];
}

/// **O5, never lock the app.** "A problem affects at most the one item
/// involved." Each probe of something the command did not touch answers on
/// the reopened profile as it did [before] or [after].
List<Violation> neverLocked({
  required String at,
  required Map<String, Object?> before,
  required Map<String, Object?> after,
  required Map<String, Object?> reopened,
}) => [
  for (final MapEntry(:key, :value) in reopened.entries)
    if (value != before[key] && value != after[key])
      Violation('O5', at, 'probe $key answered $value'),
];

/// The contract O6's losses are reported under: a game, a PGN version or
/// another program's change gone. Kept apart from an orphaned reference,
/// also O6, so that no ledger entry can pass one: a loss is never a known
/// finding.
const dataLost = 'O6-lost';

/// **O6, never delete user data.** "PGNs, training progress, puzzles and
/// saved matches are kept"; "every replaced byte is kept". The reopened
/// profile names no training key or book selector that resolves to nothing
/// unless [before] or [after] already did (O6), and still holds every game
/// and every PGN version [before] held live, somewhere: live, kept,
/// quarantined or in a history ([dataLost]).
List<Violation> nothingDeleted({
  required String at,
  required ProfileIntegrity before,
  required ProfileIntegrity after,
  required ProfileIntegrity reopened,
}) {
  Set<String> fresh(Set<String> Function(ProfileIntegrity) of) =>
      of(reopened).difference(of(before)).difference(of(after));
  return [
    for (final key in fresh((i) => i.orphanKeys))
      Violation('O6', at, 'orphaned training record $key'),
    for (final selector in fresh((i) => i.unresolvedSelectors))
      Violation('O6', at, 'orphaned book selector $selector'),
    for (final game in before.liveGames.keys)
      if (!reopened.holdsGame(game)) Violation(dataLost, at, 'lost game $game'),
    for (final file in before.liveFiles)
      if (!reopened.holdsFile(file))
        Violation(dataLost, at, 'lost the version $file'),
  ];
}

/// **O7, a transient error is deferred.** "A participant that cannot be read
/// right now leaves the record pending for the next access." Once the fault
/// clears, the next access in the same session finishes: [afterClear] has
/// no record pending. (That nothing was quarantined is O4's.)
List<Violation> transientDeferred({
  required String at,
  required ProfileSnapshot afterClear,
}) => [
  if (afterClear.pending.isNotEmpty)
    Violation(
      'O7',
      at,
      'still pending once the fault cleared: ${afterClear.pending}',
    ),
];

/// **O8, idempotent retry.** "Unknown (a lost acknowledgement: retry with
/// the same operation, never a new one that would append twice)." A retry
/// with the same id and inputs reports committed and leaves exactly
/// [after]: no row, game or file twice.
List<Violation> retryIdempotent({
  required String at,
  required Verdict retried,
  required ProfileSnapshot after,
  required ProfileSnapshot state,
}) => [
  if (retried != Verdict.committed)
    Violation('O8', at, 'the retry answered ${retried.name}'),
  if (!_same(state.projection, after.projection))
    Violation(
      'O8',
      at,
      'the retry left:\n${projectionDiff(after.projection, state.projection)}',
    ),
];

/// **O9, recovery before the affected read.** "Unfinished operations are
/// finished or quarantined before the affected file is read." The first
/// read on the reopened profile answers as it would on [before] or [after].
List<Violation> recoveredBeforeRead({
  required String at,
  required Object? before,
  required Object? after,
  required Object? reopened,
}) => [
  if (reopened != before && reopened != after)
    Violation('O9', at, 'the first read answered $reopened'),
];

/// **O10, derived data never blocks.** "A failed write of derived data is a
/// log line, not a blocked feature"; "the next run tries again". A command
/// whose derived write failed still reports committed, and the next run
/// writes it ([rewritten], when the scenario checked).
List<Violation> derivedNeverBlocks({
  required String at,
  required Verdict verdict,
  bool? rewritten,
}) => [
  if (verdict != Verdict.committed)
    Violation('O10', at, 'a derived write failed the command: ${verdict.name}'),
  if (rewritten == false)
    Violation('O10', at, 'the next run did not write the derived data again'),
];

/// **R1, flushed before published.** "Write a staged copy beside the file,
/// flush it, rename it over the file." Every staged file a command wrote is
/// synced after its last write and before it is published.
List<Violation> syncedBeforePublish(List<IoOp> trace) => [
  for (final op in trace)
    if (_publishes(op))
      if (_lastWrite(trace, op) case final written?)
        if (!trace.any(
          (o) =>
              o.kind == IoKind.sync &&
              o.key.path == op.key.path &&
              o.index > written &&
              o.index < op.index,
        ))
          Violation('R1', 'record/${op.key}', 'published unflushed bytes'),
];

/// **R2, the folder flushed before committed, and before the journal
/// goes.** "Rename it over the file, flush the directory"; "then applies
/// the steps, then removes the record". Each change to a name the profile
/// keeps has its folder synced before a [committed] command returns, and
/// before any journal record is removed after it. A change after the
/// removal is O1's to find. A trace does not say whether a mkdir made
/// anything: one of a folder in [existing] (names that were there before
/// the command) changed nothing.
List<Violation> directoriesSynced(
  List<IoOp> trace, {
  required bool committed,
  Set<String> existing = const {},
}) {
  final removals = [
    for (final op in trace)
      if (op.kind == IoKind.delete && _isRecord(op.key.path)) op.index,
  ];
  final violations = <Violation>[];
  for (final op in trace) {
    if (_madeNothing(op, existing)) continue;
    for (final folder in _foldersChanged(op)) {
      final synced = [
        for (final o in trace)
          if (o.kind == IoKind.syncDir &&
              o.key.path == folder &&
              o.index > op.index)
            o.index,
      ];
      if (committed && synced.isEmpty) {
        violations.add(
          Violation('R2', 'record/${op.key}', '$folder not flushed'),
        );
      }
      final removed = removals.where((r) => r > op.index).firstOrNull;
      if (removed != null && !synced.any((s) => s < removed)) {
        violations.add(
          Violation(
            'R2',
            'record/${op.key}',
            '$folder not flushed before a journal record was removed',
          ),
        );
      }
    }
  }
  return violations;
}

/// **R3, the journal first.** "First writes a small record under Support
/// naming each participant's before and after state, then applies the
/// steps." When a command installs a record, no authoritative path changes
/// until it is installed and its folder synced. A mkdir of a folder in
/// [existing] changed nothing.
List<Violation> journalFirst(
  List<IoOp> trace, {
  Set<String> existing = const {},
}) {
  final install = trace
      .where((op) => _changes(op) && _isRecord(_target(op)))
      .firstOrNull;
  if (install == null) return const [];
  final folder = p.posix.dirname(_target(install));
  final durable = trace
      .where(
        (op) =>
            op.kind == IoKind.syncDir &&
            op.key.path == folder &&
            op.index > install.index,
      )
      .firstOrNull;
  return [
    for (final op in trace)
      if (op.index < (durable?.index ?? trace.length) &&
          _changes(op) &&
          !_madeNothing(op, existing) &&
          _touchesRecordOfTruth(op))
        Violation('R3', 'record/${op.key}', 'changed before the journal held'),
  ];
}

/// **R4, never written in place.** "Write a staged copy beside the file,
/// flush it, rename it over the file." An authoritative path changes only
/// by publish, move, rename or delete, never by a write, create or copy on
/// the path itself, which a stop half way would leave torn.
List<Violation> noInPlaceWrites(List<IoOp> trace) => [
  for (final op in trace)
    if (((op.kind == IoKind.create || op.kind == IoKind.write) &&
            _authoritative(op.key.path)) ||
        (op.kind == IoKind.copy && _authoritative(op.key.to!)))
      Violation('R4', 'record/${op.key}', 'written in place'),
];

/// **R5, no read-back.** "Nothing is read back": the owner's Obsidian-style
/// rule. A command does not read an authoritative path after publishing it.
List<Violation> noReadBack(List<IoOp> trace) {
  final published = <String, int>{};
  final violations = <Violation>[];
  for (final op in trace) {
    if (op.kind == IoKind.read && published.containsKey(op.key.path)) {
      violations.add(Violation('R5', 'record/${op.key}', 'read back'));
    }
    if (_publishes(op) && _authoritative(op.key.to!)) {
      published[op.key.to!] = op.index;
    }
  }
  return violations;
}

bool _same(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

bool _isStaging(String relative) => classifyAny(relative) == Authority.staging;

bool _authoritative(String relative) =>
    classifyAny(relative) == Authority.authoritative;

/// A journal record rather than a journal folder.
bool _isRecord(String relative) =>
    classifyAny(relative) == Authority.journal &&
    p.posix.extension(relative).isNotEmpty;

String _target(IoOp op) => op.key.to ?? op.key.path;

/// Whether [op] changes what a path holds; a flush changes nothing.
bool _changes(IoOp op) =>
    !op.kind.reads && op.kind != IoKind.sync && op.kind != IoKind.syncDir;

bool _madeNothing(IoOp op, Set<String> existing) =>
    op.kind == IoKind.mkdir && existing.contains(op.key.path);

bool _touchesRecordOfTruth(IoOp op) =>
    _authoritative(op.key.path) ||
    (op.key.to != null && _authoritative(op.key.to!));

/// A staged file put in place under its real name.
bool _publishes(IoOp op) => switch (op.kind) {
  IoKind.publishReplace || IoKind.publishNew => true,
  IoKind.rename || IoKind.moveNoReplace => _isStaging(op.key.path),
  _ => false,
};

int? _lastWrite(List<IoOp> trace, IoOp publish) => trace
    .where(
      (o) =>
          (o.kind == IoKind.create || o.kind == IoKind.write) &&
          o.key.path == publish.key.path &&
          o.index < publish.index,
    )
    .lastOrNull
    ?.index;

/// The folders whose entries [op] changes, among those the profile keeps:
/// not staging, logs or derived data.
List<String> _foldersChanged(IoOp op) {
  bool kept(String relative) => switch (classifyAny(relative)) {
    Authority.authoritative ||
    Authority.kept ||
    Authority.recovery ||
    Authority.journal => true,
    _ => false,
  };
  final to = op.key.to;
  final from = op.key.path;
  return switch (op.kind) {
    IoKind.publishReplace ||
    IoKind.publishNew ||
    IoKind.copy ||
    IoKind.link => [if (kept(to!)) p.posix.dirname(to)],
    IoKind.rename || IoKind.moveNoReplace => {
      if (kept(to!)) p.posix.dirname(to),
      if (kept(from)) p.posix.dirname(from),
    }.toList(),
    IoKind.create ||
    IoKind.mkdir ||
    IoKind.delete => [if (kept(from)) p.posix.dirname(from)],
    _ => const [],
  };
}
