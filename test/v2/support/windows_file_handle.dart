// A real Windows reader which denies delete sharing, like an indexer or editor.
// Only constructed by Windows-native tests; nothing calls it on other hosts.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

final class WindowsFileHandle {
  WindowsFileHandle(String path) {
    final name = path.toNativeUtf16();
    try {
      _handle = _create(name, 0x80000000, 3, nullptr, 3, 0, nullptr);
      if (_handle.address == -1 || _handle.address == 0xffffffffffffffff) {
        throw StateError('CreateFileW failed: ${_error()}');
      }
    } finally {
      malloc.free(name);
    }
  }

  late Pointer<Void> _handle;
  void close() {
    if (_handle != nullptr) _close(_handle);
    _handle = nullptr;
  }

  static final _library = DynamicLibrary.open('kernel32.dll');
  static final _create = _library
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Utf16>,
          int,
          int,
          Pointer<Void>,
          int,
          int,
          Pointer<Void>,
        )
      >('CreateFileW');
  static final _close = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  static final _error = _library
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
}
