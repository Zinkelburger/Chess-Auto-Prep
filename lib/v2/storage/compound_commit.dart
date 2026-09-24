/// The exact two participants of a committed course-section edit. Kept with
/// the document receipt so its inverse can validate both current versions.
final class CompoundCommit {
  const CompoundCommit({
    required this.id,
    required this.documentPath,
    required this.documentBefore,
    required this.documentAfter,
    required this.booksBefore,
    required this.booksAfter,
  });

  final String id;
  final String documentPath;
  final String documentBefore;
  final String documentAfter;
  final String? booksBefore;
  final String? booksAfter;
}
