/// Where a newly created repertoire landed.
class RepertoireCreationResult {
  RepertoireCreationResult({
    required this.directoryPath,
    required this.chapterPath,
    required this.gameCount,
    List<String>? chapterPaths,
  }) : chapterPaths = List.unmodifiable(chapterPaths ?? [chapterPath]);

  /// The repertoire folder — what [MyRepertoireSettings] designates.
  final String directoryPath;

  /// Its first chapter — what an editor opens. A course export is split
  /// into one file per course chapter (see the repertoire repository); this is then
  /// the first of them, in the course's order.
  final String chapterPath;

  /// Every chapter file written, in order; one entry unless the import was
  /// a course export with chapters of its own.
  final List<String> chapterPaths;

  /// Lines the chapter holds after import, every variation counted as its
  /// own line; 0 for an empty repertoire.
  final int gameCount;
}

/// A repertoire could not be created because its first chapter is already on
/// disk. Thrown rather than silently overwriting it.
class RepertoireExistsException implements Exception {
  const RepertoireExistsException(this.name);

  final String name;

  @override
  String toString() => 'A repertoire named "$name" already exists.';
}

/// Validated by the repository before any external mutation.
class CreateRepertoire {
  const CreateRepertoire({
    required this.name,
    required this.color,
    this.pgnContent,
    this.gameCount = 0,
    this.chapterName = 'Main',
    this.splitChapters = true,
  });

  final String name;
  final String color;
  final String? pgnContent;
  final int gameCount;
  final String chapterName;
  final bool splitChapters;
}

/// Namespace installation may have completed; retain the draft and inspect the
/// library before issuing another creation request. Never retry automatically.
class RepertoireCreationUncertain implements Exception {
  const RepertoireCreationUncertain({
    this.cause,
    this.createdPaths = const [],
    this.pathsToInspect = const [],
  });
  final Object? cause;
  final List<String> createdPaths;
  final List<String> pathsToInspect;
  @override
  String toString() =>
      'The file may already be saved. Keep this draft and reload the library before retrying.';
}

/// Private preparation failed before any folder could be published.
class RepertoirePreparationFailed implements Exception {
  const RepertoirePreparationFailed(this.cause);
  final Object cause;
  @override
  String toString() =>
      'Import preparation failed. No repertoire was published. Keep this draft and retry.';
}
