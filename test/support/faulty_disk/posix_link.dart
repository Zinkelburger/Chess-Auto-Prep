// link(2), for the state a kill inside installNewFile leaves on POSIX: the
// new name made, the staged name not yet removed.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Gives [existing] the second name [name], as the first half of
/// installNewFile does. POSIX only; the Windows publish has no such state.
void linkPosix(String existing, String name) {
  if (Platform.isWindows) {
    throw UnsupportedError('A second hard name is a POSIX midway state');
  }
  final from = existing.toNativeUtf8(), to = name.toNativeUtf8();
  try {
    if (_link(from, to) != 0) {
      throw FileSystemException('link failed', name);
    }
  } finally {
    malloc.free(from);
    malloc.free(to);
  }
}

final _link = DynamicLibrary.process()
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
      int Function(Pointer<Utf8>, Pointer<Utf8>)
    >('link');
