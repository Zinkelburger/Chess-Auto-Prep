import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:onnxruntime/onnxruntime.dart';

typedef _Status = Pointer<Void>;
typedef _Handle = Pointer<Void>;

/// The five ONNX Runtime C entry points the Dart wrapper does not reach.
typedef _SessionCalls = ({
  _Status Function(Pointer<_Handle>) createOptions,
  _Status Function(_Handle, int) setIntraOpThreads,
  _Status Function(_Handle) disableMemPattern,
  _Status Function(_Handle, _Handle, int, _Handle, Pointer<_Handle>)
  createSession,
  void Function(_Handle) releaseOptions,
});

/// Builds the ONNX session for [model] and returns its native address.
///
/// Two session options decide whether the opponent model is reproducible,
/// and the Dart wrapper exposes neither, so they are set through the C API
/// before the session exists. Memory patterns are off because with this
/// runtime and this model the first run and every later run otherwise
/// disagree in the fourth decimal — 0.9220 against 0.9206 for the same
/// position (docs/PARALLEL_EXPECTIMAX.md) — and a tree built from numbers
/// that change on the second ask cannot be reproduced or compared. One
/// intra-op thread is the other half of that: the runtime's thread pool
/// sums partial results in whatever order the threads finish.
///
/// Meant to be called inside `Isolate.run`. Parsing 45 MB of graph is one
/// long synchronous native call, which would stop the app dead; the session
/// outlives the isolate and is adopted with `OrtSession.fromAddress`.
int createMaiaSession(Uint8List model) {
  final calls = _bind();
  final options = calloc<_Handle>();
  final session = calloc<_Handle>();
  final buffer = calloc<Uint8>(model.length);
  void check(_Status status) => OrtStatus.checkOrtStatus(status.cast());
  try {
    check(calls.createOptions(options));
    check(calls.setIntraOpThreads(options.value, 1));
    check(calls.disableMemPattern(options.value));
    buffer.asTypedList(model.length).setAll(0, model);
    check(
      calls.createSession(
        OrtEnv.instance.ptr.cast(),
        buffer.cast(),
        model.length,
        options.value,
        session,
      ),
    );
    return session.value.address;
  } finally {
    if (options.value != nullptr) calls.releaseOptions(options.value);
    calloc.free(buffer);
    calloc.free(session);
    calloc.free(options);
  }
}

_SessionCalls _bind() {
  final api = OrtEnv.instance.ortApiPtr.ref;
  return (
    createOptions:
        api.CreateSessionOptions.cast<
              NativeFunction<_Status Function(Pointer<_Handle>)>
            >()
            .asFunction(),
    setIntraOpThreads:
        api.SetIntraOpNumThreads.cast<
              NativeFunction<_Status Function(_Handle, Int32)>
            >()
            .asFunction(),
    disableMemPattern:
        api.DisableMemPattern.cast<NativeFunction<_Status Function(_Handle)>>()
            .asFunction(),
    createSession:
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
            .asFunction(),
    releaseOptions:
        api.ReleaseSessionOptions.cast<NativeFunction<Void Function(_Handle)>>()
            .asFunction(),
  );
}
