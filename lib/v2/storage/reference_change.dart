import 'dart:math';

/// An accepted change to the name of a section in one course file. This
/// travels with the draft until its PGN and references are committed together.
final class SectionRename {
  const SectionRename({
    required this.path,
    required this.from,
    required this.to,
  });

  final String path;
  final String from;
  final String to;
}

/// One immutable command identity retained through a save's exact retries.
/// Combining drafts makes a new command; retrying the same draft keeps it.
final class ReferenceChanges {
  ReferenceChanges(Iterable<SectionRename> changes)
    : id = newCompoundId(),
      changes = List.unmodifiable(changes);

  final String id;
  final List<SectionRename> changes;
}

String newCompoundId() =>
    '${DateTime.now().microsecondsSinceEpoch}-'
    '${Random.secure().nextInt(1 << 32).toRadixString(16)}';
