// A storage command as the fault matrix runs it: how to seed the profile,
// open the stores, run the command and say what it answered, and what to
// read afterwards. A scenario is one top-level value whose callbacks capture
// nothing but constants, so it can be sent to the isolate each phase runs in.
import 'package:chess_auto_prep/storage/pgn_document_store.dart';

import '../profile/profile.dart';
import 'contracts.dart';
import 'perturbations.dart';

/// The ways the matrix runs a command.
enum Family {
  /// Killed before, then after, each effect; reopened in a new isolate.
  crash,

  /// Killed half way through each effect made of several steps.
  crashMidway,

  /// An I/O error at each effect, once; the same session then goes on.
  transient,

  /// The answer to each effect lost once; the same session retries.
  lostAck,

  /// An I/O error at each effect of the recovery a crash left pending.
  recoveryFault,

  /// A file briefly missing at each read of that recovery.
  recoveryMissing,

  /// A second kill at each effect of that recovery, then a third start.
  recoveryCrash,

  /// Another program changes the profile between a crash and the reopen.
  perturbed,
}

/// Something the app reads that the command does not change, or changes
/// only as the command says: it must answer on the reopened profile as it
/// did before the command or after it.
final class Probe<S> {
  const Probe(this.name, this.read);
  final String name;
  final Future<String> Function(S stores) read;
}

final class StorageScenario<S, R> {
  const StorageScenario({
    required this.name,
    required this.seed,
    required this.open,
    required this.command,
    required this.verdict,
    required this.firstRead,
    this.retry,
    this.probes = const [],
    this.perturbations = const [],
    this.known = const {},
  });

  final String name;

  /// Fills an empty profile, with plain dart:io; runs once per scenario.
  final Future<void> Function(Profile profile) seed;

  /// The stores, built inside the run.
  final S Function(Profile profile) open;

  /// The command under test, with fixed inputs and operation ids.
  final Future<R> Function(S stores) command;

  /// Committed, rejected or unknown, from what [command] answered.
  final Verdict Function(R result) verdict;

  /// The same operation again, as the app retries after an unknown answer.
  final Future<R> Function(S stores)? retry;

  /// The first read after a restart, of what the command changes; the
  /// reopened profile must answer it as before or after the command (O9).
  final Future<String> Function(S stores) firstRead;

  final List<Probe<S>> probes;

  /// Changes another program makes between a crash and the reopen.
  final List<Perturbation> perturbations;

  /// The violations already confirmed as findings, by
  /// `<family>/<case>/<contract>` (as a report prints them; `*` stands for
  /// any run of characters), each naming its finding. A violation not
  /// listed fails the matrix, and so does a finding none of whose entries
  /// shows any more where their cases ran, so the ledger only ever shrinks.
  /// A quick run samples the faults inside a recovery, so there only a full
  /// run (`CAP_FAULT_DEPTH=full`) can say a `*` entry stopped showing.
  final Map<String, String> known;

  /// The families that apply: perturbed only with perturbations.
  Set<Family> get families => {
    for (final family in Family.values)
      if (family != Family.perturbed || perturbations.isNotEmpty) family,
  };
}

/// A create: made, refused because the name is taken, or unknown.
Verdict createVerdict(CreateResult result) => switch (result) {
  Created() => Verdict.committed,
  Collision() => Verdict.rejected,
  IoFailure() => Verdict.unknown,
};

/// A save: saved, refused (a conflict or a check), or unknown.
Verdict saveVerdict(SaveResult result) => switch (result) {
  Saved() => Verdict.committed,
  IoFailure() => Verdict.unknown,
  Conflict() || SaveDidNotLand() => Verdict.rejected,
};

/// A move or rename: moved, refused (the name taken, the file changed), or
/// unknown.
Verdict moveVerdict(MoveResult result) => switch (result) {
  Moved() => Verdict.committed,
  IoFailure() => Verdict.unknown,
  Collision() || Conflict() => Verdict.rejected,
};

/// A delete: set aside, refused because the file changed, or unknown.
Verdict deleteVerdict(DeleteResult result) => switch (result) {
  Deleted() => Verdict.committed,
  IoFailure() => Verdict.unknown,
  Conflict() => Verdict.rejected,
};

/// A folder move: moved, refused because the name is taken, or unknown:
/// a failed one may have landed, and its retry finishes it.
Verdict folderMoveVerdict(FolderMoveResult result) => switch (result) {
  FolderMoved() => Verdict.committed,
  FolderNameTaken() => Verdict.rejected,
  FolderMoveFailed() => Verdict.unknown,
};
