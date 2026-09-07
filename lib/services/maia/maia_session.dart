/// Native session construction for the bundled Maia model.
/// The Dart ORT wrapper does not expose DisableMemPattern or an options handle.
library;

import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:onnxruntime/onnxruntime.dart';

typedef _Status = Pointer<Void>;
typedef _Handle = Pointer<Void>;

/// Keep first and subsequent inference on the same allocation path. With the
/// bundled runtime/model, memory patterns change probabilities after the first
/// run. See docs/PARALLEL_EXPECTIMAX.md and the native repeatability regression.
/// Runs in the model-loading isolate; the returned session is adopted by Dart.
int createMaiaSession(Uint8List bytes) {
  final api = OrtEnv.instance.ortApiPtr.ref;
  final options = calloc<_Handle>();
  final session = calloc<_Handle>();
  final buffer = calloc<Uint8>(bytes.length);
  void check(_Status status) => OrtStatus.checkOrtStatus(status.cast());
  try {
    check(
      api.CreateSessionOptions.cast<
            NativeFunction<_Status Function(Pointer<_Handle>)>
          >()
          .asFunction<_Status Function(Pointer<_Handle>)>()(options),
    );
    check(
      api.SetIntraOpNumThreads.cast<
            NativeFunction<_Status Function(_Handle, Int32)>
          >()
          .asFunction<_Status Function(_Handle, int)>()(options.value, 1),
    );
    check(
      api.DisableMemPattern.cast<NativeFunction<_Status Function(_Handle)>>()
          .asFunction<_Status Function(_Handle)>()(options.value),
    );
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    check(
      api.CreateSessionFromArray.cast<
            NativeFunction<
              _Status Function(
                _Handle,
                _Handle,
                IntPtr,
                _Handle,
                Pointer<_Handle>,
              )
            >
          >()
          .asFunction<
            _Status Function(_Handle, _Handle, int, _Handle, Pointer<_Handle>)
          >()(
        OrtEnv.instance.ptr.cast(),
        buffer.cast(),
        bytes.length,
        options.value,
        session,
      ),
    );
    return session.value.address;
  } finally {
    if (options.value != nullptr) {
      api.ReleaseSessionOptions.cast<NativeFunction<Void Function(_Handle)>>()
          .asFunction<void Function(_Handle)>()(options.value);
    }
    calloc.free(buffer);
    calloc.free(session);
    calloc.free(options);
  }
}
