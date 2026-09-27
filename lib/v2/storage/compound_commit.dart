/// Exact before/after words for one existing PGN participant.
final class CompoundDocument {
  const CompoundDocument({
    required this.path,
    required this.before,
    required this.after,
  });

  final String path;
  final String before;
  final String after;
}

/// A retained edit: one PGN and books, or two PGNs and their training files.
/// Every participant belongs to the same guarded inverse and exact retry.
final class CompoundCommit {
  const CompoundCommit({
    required this.id,
    required this.documentPath,
    required this.documentBefore,
    required this.documentAfter,
    required this.booksBefore,
    required this.booksAfter,
  }) : secondary = null,
       training = const [];

  CompoundCommit.pair({
    required this.id,
    required CompoundDocument primary,
    required CompoundDocument this.secondary,
    List<CompoundTraining> training = const [],
  }) : training = List.unmodifiable(training),
       documentPath = primary.path,
       documentBefore = primary.before,
       documentAfter = primary.after,
       booksBefore = null,
       booksAfter = null;

  final String id;
  final String documentPath;
  final String documentBefore;
  final String documentAfter;
  final String? booksBefore;
  final String? booksAfter;
  final CompoundDocument? secondary;
  final List<CompoundTraining> training;

  CompoundDocument get primary => CompoundDocument(
    path: documentPath,
    before: documentBefore,
    after: documentAfter,
  );

  /// Primary first: publication order is fixed in the retained manifest.
  List<CompoundDocument> get documents => [primary, ?secondary];
}

/// Exact snapshots of a training file participating in a line move and undo.
final class CompoundTraining {
  const CompoundTraining({
    required this.name,
    required this.before,
    required this.after,
  });
  final String name;
  final String? before;
  final String? after;
  CompoundTraining get inverse =>
      CompoundTraining(name: name, before: after, after: before);
  Map<String, Object?> toJson() => {
    'name': name,
    'before': before,
    'after': after,
  };
}
