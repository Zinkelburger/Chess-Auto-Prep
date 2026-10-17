import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../chess/pgn/chapter.dart' show readOffThreadFrom;
import 'document_text.dart';
import 'edit_scope.dart';
import 'pgn_document_store.dart';
import 'section_reference_check.dart';

/// [bytes] as a document. A small file is decoded here; a large one on
/// another isolate, because decoding megabytes is work the screen would
/// otherwise wait for.
Future<DocumentText> decodedDocument(Uint8List bytes) =>
    bytes.length < readOffThreadFrom
    ? Future.value(readDocumentText(bytes))
    : Isolate.run(() => readDocumentText(bytes));

/// [text] as the bytes a file will hold, and their hash.
Future<({Uint8List bytes, String hash})> encodedDocument(String text) =>
    text.length < readOffThreadFrom
    ? Future.value(_encode(text))
    : Isolate.run(() => _encode(text));

/// What a save works out before it writes, on another isolate once either
/// side of the comparison is big enough to be worth the trip.
Future<PreparedSave> preparedSave(
  String documentPath,
  Uint8List current,
  String currentHash,
  String text,
  EditScope scope,
) => current.length < readOffThreadFrom && text.length < readOffThreadFrom
    ? Future.value(_prepare(documentPath, current, currentHash, text, scope))
    : Isolate.run(
        () => _prepare(documentPath, current, currentHash, text, scope),
      );

({Uint8List bytes, String hash}) _encode(String text) {
  final bytes = utf8.encode(text);
  return (bytes: bytes, hash: sha256.convert(bytes).toString());
}

/// Everything a save works out before it touches the disk: whether the
/// current bytes may be replaced at all, whether the new text changes only
/// what the scope declared, and the bytes and hash to write.
sealed class PreparedSave {
  const PreparedSave();
}

/// The file on disk is not one this app may replace; [result] says so.
final class NotReplaceable extends PreparedSave {
  const NotReplaceable(this.result, this.detail);

  final SaveResult result;
  final String detail;
}

/// The text would change a game the save did not declare.
final class OutsideScope extends PreparedSave {
  const OutsideScope(this.detail);

  final String detail;
}

/// The text is already what the file holds.
final class UnchangedText extends PreparedSave {
  const UnchangedText(this.before);

  final String before;
}

final class ReadyToWrite extends PreparedSave {
  const ReadyToWrite({
    required this.before,
    required this.bytes,
    required this.hash,
    required this.undeclared,
  });

  /// The text being replaced, as it was read from disk.
  final String before;

  final Uint8List bytes;
  final String hash;

  /// Whether the save replaced the whole document without saying which
  /// game it changed, which is logged so that a writer that does it is
  /// visible.
  final bool undeclared;
}

/// Runs on another isolate: everything about a save that reads every byte.
PreparedSave _prepare(
  String documentPath,
  Uint8List current,
  String currentHash,
  String text,
  EditScope scope,
) {
  final read = readDocumentText(current);
  // A document this app cannot read is not one it may replace: a save over
  // a compressed chapter would leave bytes no reader can open.
  if (read case NotText(:final detail)) {
    return NotReplaceable(IoFailure(detail), detail);
  }
  // Nor one it had to guess at: this writes UTF-8, so putting a Latin-1
  // file back would change every game holding an accented letter.
  if (read case ForeignText(:final detail)) {
    return NotReplaceable(NotWritable(detail), detail);
  }
  final before = (read as PlainText).text;
  final referenceProblem = sectionReferenceProblem(
    documentPath: documentPath,
    before: before,
    after: text,
    scope: scope,
  );
  if (referenceProblem != null) return OutsideScope(referenceProblem);
  final encoded = _encode(text);
  if (encoded.hash == currentHash) return UnchangedText(before);
  final outside = changeOutsideScope(
    previous: current,
    next: encoded.bytes,
    scope: scope,
  );
  if (outside != null) return OutsideScope(outside);
  return ReadyToWrite(
    before: before,
    bytes: encoded.bytes,
    hash: encoded.hash,
    undeclared: scope is WholeDocument,
  );
}
