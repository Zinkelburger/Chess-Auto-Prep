/// A PGN file under the app's documents root, named by its absolute path.
///
/// This is the one identity for "a file the store owns"; [ChapterRef] in
/// `chapter_files.dart` is this type with the two labels the library list
/// shows.
base class DocumentRef {
  const DocumentRef(this.path);

  /// Absolute, as the operating system spells it.
  final String path;

  /// The chapter of the file this names, when the file holds several by
  /// tag (`ChapterRef.section`); null for the file as a whole. Two refs to
  /// one file are one document only when they name the same part of it.
  String? get section => null;

  @override
  bool operator ==(Object other) =>
      other is DocumentRef && other.path == path && other.section == section;

  @override
  int get hashCode => Object.hash(path, section);

  @override
  String toString() => path;
}

/// What a document held when it was read: the SHA-256 of the exact bytes.
///
/// A save proceeds only when the file still hashes to this. Other bytes under
/// the name mean someone else edited the document, and the user's save would
/// be writing over an answer it never saw, so that is a conflict. The same
/// bytes are the same document, whichever file they arrived in: replacing
/// them with the user's draft loses nothing.
final class Revision {
  const Revision(this.contentHash, {this.nativeIdentity});

  /// Native object observed with these bytes, when supplied by disk. Content
  /// equality remains the save contract; training also checks this identity
  /// so a reused path with equal PGN bytes cannot inherit an old answer.
  final String? nativeIdentity;

  /// Lowercase hex SHA-256 of the file's bytes.
  final String contentHash;

  @override
  bool operator ==(Object other) =>
      other is Revision && other.contentHash == contentHash;

  @override
  int get hashCode => contentHash.hashCode;

  @override
  String toString() => contentHash.substring(0, 8);
}
