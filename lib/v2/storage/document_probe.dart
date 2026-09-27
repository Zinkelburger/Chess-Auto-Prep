import 'dart:typed_data';

import 'package:document_file_io/document_file_io.dart';

import 'document_ref.dart';

/// One look at a file: its bytes and its revision, or why neither is here.
sealed class Probe {
  const Probe();
}

final class FileFound extends Probe {
  const FileFound(this.bytes, this.revision, {required this.identity});

  final Uint8List bytes;
  final Revision revision;

  /// The native object identity (device and inode on Linux), from the same
  /// open handle as the bytes. A move writes it down so that a move which
  /// stopped half way can be finished by the file rather than by its name.
  final String identity;
}

final class FileMissing extends Probe {
  const FileMissing();
}

/// The file is there but its bytes could not be trusted: no permission, not a
/// regular file, or it changed underneath the read. Never an empty document.
final class FileUnreadable extends Probe {
  const FileUnreadable(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

/// Reads bytes, hash and native identity from one open handle, on another
/// isolate, so the revision describes the bytes it came with rather than
/// whatever the name points at by the time the caller looks again.
Future<Probe> probeDocument(String path) async {
  try {
    return _interpret(await observeFile(path));
  } on Object catch (error) {
    return FileUnreadable('$error');
  }
}

Probe _interpret(NativeFileObservation observation) {
  if (observation.status == _missing) return const FileMissing();
  final bytes = observation.bytes;
  final hash = observation.sha256Hex;
  final identity = observation.identity;
  if (bytes == null || hash == null || identity == null) {
    return FileUnreadable(_reason(observation));
  }
  return FileFound(
    bytes,
    Revision(hash, nativeIdentity: identity),
    identity: identity,
  );
}

const _missing = 1;

String _reason(NativeFileObservation observation) =>
    switch (observation.status) {
      3 => 'the file changed while it was being read',
      4 => 'not a plain file this app can read',
      _ => 'the file could not be read (error ${observation.error})',
    };
