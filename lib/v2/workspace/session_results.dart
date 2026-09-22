/// What the session answers when it is asked to open a document or to write
/// one somewhere else.
///
/// Typed, because every one of these is something the screen has to say: an
/// open that failed, an open a later click overtook, a copy whose name was
/// taken. The widget writes the sentences.
library;

sealed class OpenResult {
  const OpenResult();
}

final class DocumentOpened extends OpenResult {
  const DocumentOpened();
}

final class OpenFailed extends OpenResult {
  const OpenFailed(this.reason);

  /// A sentence for the screen.
  final String reason;
}

/// A later open took over. This one changed nothing and has nothing to say.
final class OpenOvertaken extends OpenResult {
  const OpenOvertaken();
}

sealed class CopyResult {
  const CopyResult();
}

final class CopySaved extends CopyResult {
  const CopySaved(this.name, {this.nowEditing = false});

  /// The file name the copy was written under.
  final String name;

  /// Whether the session is now on the copy. A document that cannot take
  /// words any more — a stopped save, a file this app may not write — has
  /// nowhere else to put them, so the copy becomes the document.
  final bool nowEditing;
}

/// The name is taken. Nothing was written and nothing was replaced.
final class CopyNameTaken extends CopyResult {
  const CopyNameTaken();
}

final class CopyFailed extends CopyResult {
  const CopyFailed(this.detail);

  final String detail;
}
