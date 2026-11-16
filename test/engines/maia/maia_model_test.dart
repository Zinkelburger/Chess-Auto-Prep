import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/engines/maia/maia_model.dart';
import 'package:chess_auto_prep/engines/maia/move_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path/path.dart' as p;

/// The smallest model ONNX Runtime loads, `y = Identity(x)` over one float,
/// written out field by field from `onnx.proto`. It is no opponent model:
/// its one input is not among those Maia is asked with, so every run of it
/// fails inside the runtime, which is the failure under test.
final _wrongModel = base64Decode(
  'CAc6NwoQCgF4EgF5IghJZGVudGl0eRIBZ1oPCgF4EgoKCAgBEgQK'
  'AggBYg8KAXkSCgoICAESBAoCCAFCAhAN',
);

/// The runtime the `onnxruntime` package ships for Linux. A test has no app
/// bundle to find it in, so it is loaded from the package by its full path,
/// and the package's own lookup by name then finds it in the process.
String? _shippedRuntime() {
  if (!Platform.isLinux) return null;
  final config = File(p.join('.dart_tool', 'package_config.json')).absolute;
  if (!config.existsSync()) return null;
  final packages =
      (jsonDecode(config.readAsStringSync())
              as Map<String, Object?>)['packages']
          as List<Object?>;
  for (final package in packages.cast<Map<String, Object?>>()) {
    if (package['name'] != 'onnxruntime') continue;
    final root = config.uri.resolve('${package['rootUri']}/').toFilePath();
    final library = File(p.join(root, 'linux', 'libonnxruntime.so.1.15.1'));
    return library.existsSync() ? library.path : null;
  }
  return null;
}

/// The model the app ships, with the move table it is read through.
const String _shippedModel = 'assets/maia3_simplified.onnx';
const String _moveTable = 'assets/data/all_moves_maia3.json';

/// What `tree_builder`'s own Maia (`tree_builder/src/maia.c`: its own board
/// encoding, legal-move mask and softmax, the same model and ONNX Runtime
/// 1.15.1) gives for these positions: the number of legal moves and the
/// likeliest three with their shares. Two implementations that share
/// nothing but the model file agree to five decimals, so a Dart answer that
/// drifts from these has misread the network, not disagreed with it. The
/// king-and-pawn ending at 2200 is the position quoted in
/// docs/ALGORITHM.md#maia-repeatability.
const List<(String, int, int, List<(String, double)>)> _builderAnswers = [
  (
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    1500,
    20,
    [('e2e4', 0.61642), ('d2d4', 0.26512), ('c2c4', 0.03371)],
  ),
  (
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    2200,
    20,
    [('e2e4', 0.50238), ('d2d4', 0.31933), ('g1f3', 0.07238)],
  ),
  (
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
    1500,
    20,
    [('e7e5', 0.40103), ('d7d5', 0.18076), ('c7c5', 0.10461)],
  ),
  (
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
    2200,
    20,
    [('c7c5', 0.29270), ('e7e5', 0.18033), ('e7e6', 0.12394)],
  ),
  (
    '8/8/8/8/P7/3k4/8/4K3 b - - 0 2',
    2200,
    6,
    [('d3c4', 0.92199), ('d3d4', 0.05202), ('d3c3', 0.02069)],
  ),
  (
    'r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 4 4',
    1500,
    42,
    [('f3f7', 0.84197), ('c2c3', 0.05383), ('g1e2', 0.03421)],
  ),
  (
    '4k3/P7/8/8/8/8/8/4K3 w - - 0 1',
    2200,
    9,
    [('a7a8q', 0.90506), ('a7a8r', 0.04436), ('e1d2', 0.02231)],
  ),
];

/// The threads of this process by id, each with its name. A thread the
/// runtime starts inherits the name of the thread that started it.
Map<String, String> _threads() => {
  for (final task in Directory('/proc/self/task').listSync())
    p.basename(task.path): File(
      p.join(task.path, 'comm'),
    ).readAsStringSync().trim(),
};

/// glibc's `struct mallinfo2`: the bytes `malloc` has handed out and not
/// had back, in its arenas (`uordblks`) and in its own mappings (`hblkhd`).
final class _MallInfo2 extends Struct {
  @Size()
  external int arena;
  @Size()
  external int ordblks;
  @Size()
  external int smblks;
  @Size()
  external int hblks;
  @Size()
  external int hblkhd;
  @Size()
  external int usmblks;
  @Size()
  external int fsmblks;
  @Size()
  external int uordblks;
  @Size()
  external int fordblks;
  @Size()
  external int keepcost;
}

/// Native heap in use, or null off glibc. The runtime allocates every
/// session, option set and tensor with `malloc`, so what it does not give
/// back shows here.
final int Function()? _nativeHeapInUse = () {
  try {
    final info = DynamicLibrary.process()
        .lookupFunction<_MallInfo2 Function(), _MallInfo2 Function()>(
          'mallinfo2',
        );
    return () {
      final now = info();
      return now.uordblks + now.hblkhd;
    };
  } on ArgumentError {
    return null;
  }
}();

/// The runtime's own `ReleaseSession`, so a session can be dropped without
/// the wrapper's `OrtSession.fromAddress`, which allocates its name lists.
void _releaseSession(int address) => OrtEnv
    .instance
    .ortApiPtr
    .ref
    .ReleaseSession
    .cast<NativeFunction<Void Function(Pointer<Void>)>>()
    .asFunction<void Function(Pointer<Void>)>()(Pointer.fromAddress(address));

void main() {
  final runtime = _shippedRuntime();
  final shipped = runtime != null && File(_shippedModel).existsSync();
  const needsShipped = 'needs the ONNX Runtime and the shipped Maia model';

  setUpAll(() {
    if (runtime != null) DynamicLibrary.open(runtime);
  });

  test(
    'a run that fails inside the runtime is answered, and so is every '
    'question after it',
    () async {
      final load = await MaiaModel.load(
        model: _wrongModel,
        moveVocabulary: File(
          'assets/data/all_moves_maia3.json',
        ).readAsStringSync(),
      );
      final model = switch (load) {
        MaiaReady(:final model) => model,
        MaiaUnavailable(:final reason) => fail(reason),
      };
      // Far longer than one run takes; a question that is never answered
      // fails here rather than at the test's own timeout.
      const patience = Duration(seconds: 20);

      final first = await model.policy(Fen.initial, 1500).timeout(patience);
      expect(first, isA<MaiaFailed>());
      final second = await model.policy(Fen.initial, 1500).timeout(patience);
      expect(second, isA<MaiaFailed>(), reason: 'the queue did not stop');

      // Disposing while a question is on its way still answers it.
      final pending = model.policy(Fen.initial, 1500);
      model.dispose();
      expect(await pending.timeout(patience), isA<MaiaFailed>());
      expect(
        await model.policy(Fen.initial, 1500),
        isA<MaiaFailed>().having((f) => f.reason, 'reason', contains('shut')),
      );
    },
    skip: runtime == null
        ? 'needs the ONNX Runtime the onnxruntime package ships for Linux'
        : false,
  );

  test(
    'the shipped model gives the shares the tree builder gives, for either '
    'side to move, promotions included',
    () async {
      final load = await MaiaModel.load(
        model: File(_shippedModel).readAsBytesSync(),
        moveVocabulary: File(_moveTable).readAsStringSync(),
      );
      final model = switch (load) {
        MaiaReady(:final model) => model,
        MaiaUnavailable(:final reason) => fail(reason),
      };
      addTearDown(model.dispose);
      const patience = Duration(seconds: 60);
      for (final (fen, elo, legal, likeliest) in _builderAnswers) {
        final answer = await model.policy(Fen(fen), elo).timeout(patience);
        final shares = switch (answer) {
          MaiaPolicy(:final shares) => shares,
          MaiaFailed(:final reason) => fail(reason),
        };
        final where = '$fen at $elo';
        expect(shares, hasLength(legal), reason: where);
        final total = shares.values.fold<double>(0, (a, b) => a + b);
        expect(total, closeTo(1, 1e-6), reason: where);
        expect(shares.keys.take(likeliest.length), [
          for (final (move, _) in likeliest) move,
        ], reason: where);
        for (final (move, share) in likeliest) {
          expect(shares[move], closeTo(share, 5e-5), reason: '$move, $where');
        }
      }
    },
    skip: shipped ? false : needsShipped,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('the session runs on the calling thread alone: building it starts no '
      'thread pool', () {
    // Built here rather than in an isolate, so the only thread that can
    // start a pool is this one, and the pool would carry its name.
    OrtEnv.instance.init();
    final model = File(_shippedModel).readAsBytesSync();
    final self = File('/proc/thread-self/comm').readAsStringSync().trim();
    final before = _threads();
    final session = createMaiaSession(model);
    final started = {
      for (final MapEntry(:key, :value) in _threads().entries)
        if (!before.containsKey(key) && value == self) key,
    };
    _releaseSession(session);
    // One intra-op thread is what keeps a policy the same from run to
    // run (docs/ALGORITHM.md#maia-repeatability); two would start one
    // worker here, the runtime's default one per core.
    expect(started, isEmpty);
  }, skip: shipped ? false : needsShipped);

  test(
    'building and releasing a session again and again leaves nothing behind',
    () {
      OrtEnv.instance.init();
      void cycle() => _releaseSession(createMaiaSession(_wrongModel));
      final inUse = _nativeHeapInUse!;
      for (var i = 0; i < 100; i++) {
        cycle();
      }
      // Session options never released cost about 550 bytes a session.
      // Another thread can allocate or free during a batch, so the middle
      // batch is the one judged.
      const cycles = 200;
      final perSession = <double>[];
      for (var batch = 0; batch < 7; batch++) {
        final start = inUse();
        for (var i = 0; i < cycles; i++) {
          cycle();
        }
        perSession.add((inUse() - start) / cycles);
      }
      perSession.sort();
      expect(perSession[3], lessThan(200), reason: 'bytes kept: $perSession');
    },
    skip: runtime == null || _nativeHeapInUse == null
        ? 'needs the ONNX Runtime and glibc'
        : false,
  );

  test(
    'disposing the shipped model gives its weights back',
    () async {
      final bytes = File(_shippedModel).readAsBytesSync();
      final table = File(_moveTable).readAsStringSync();
      final inUse = _nativeHeapInUse!;
      Future<void> cycle() async {
        final load = await MaiaModel.load(model: bytes, moveVocabulary: table);
        final model = switch (load) {
          MaiaReady(:final model) => model,
          MaiaUnavailable(:final reason) => fail(reason),
        };
        expect(await model.policy(Fen.initial, 1500), isA<MaiaPolicy>());
        model.dispose();
        // The release waits on the queue, which is already empty.
        await Future<void>.delayed(Duration.zero);
      }

      await cycle();
      final start = inUse();
      for (var i = 0; i < 3; i++) {
        await cycle();
      }
      // A session kept alive holds the 45 MB of weights and more.
      expect(inUse() - start, lessThan(20 << 20));
    },
    skip: shipped && _nativeHeapInUse != null ? false : '$needsShipped, glibc',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
