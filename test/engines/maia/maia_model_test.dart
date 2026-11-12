import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/engines/maia/maia_model.dart';
import 'package:chess_auto_prep/engines/maia/move_policy.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  final runtime = _shippedRuntime();

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
    'the shipped model answers a position with shares over its legal moves, '
    'for either side to move',
    () async {
      final load = await MaiaModel.load(
        model: File('assets/maia3_simplified.onnx').readAsBytesSync(),
        moveVocabulary: File(
          'assets/data/all_moves_maia3.json',
        ).readAsStringSync(),
      );
      final model = switch (load) {
        MaiaReady(:final model) => model,
        MaiaUnavailable(:final reason) => fail(reason),
      };
      addTearDown(model.dispose);
      const patience = Duration(seconds: 60);
      for (final (fen, legal) in [
        (Fen.initial, 20),
        (
          const Fen(
            'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
          ),
          20,
        ),
      ]) {
        final answer = await model.policy(fen, 1500).timeout(patience);
        final shares = switch (answer) {
          MaiaPolicy(:final shares) => shares,
          MaiaFailed(:final reason) => fail(reason),
        };
        expect(shares, hasLength(legal), reason: fen.value);
        final total = shares.values.fold<double>(0, (a, b) => a + b);
        expect(total, closeTo(1, 1e-3));
        expect(shares.values, everyElement(inInclusiveRange(0, 1)));
      }
      final white = await model.policy(Fen.initial, 1500) as MaiaPolicy;
      expect(white.shares.keys, containsAll(['e2e4', 'd2d4']));
      final black =
          await model.policy(
                const Fen(
                  'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
                ),
                1500,
              )
              as MaiaPolicy;
      expect(black.shares.keys, containsAll(['e7e5', 'c7c5']));
    },
    skip: runtime == null || !File('assets/maia3_simplified.onnx').existsSync()
        ? 'needs the ONNX Runtime and the shipped Maia model'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
