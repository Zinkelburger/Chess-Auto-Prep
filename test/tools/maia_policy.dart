/// Ask Maia what it thinks a side plays in a position, exactly as the tree
/// build asks it. Answers "why did the build only look at one reply here?"
/// without re-running a build.
///
/// Deliberately has no `_test` suffix so a bare `flutter test` never runs it.
/// Needs the onnxruntime shared library on LD_LIBRARY_PATH:
///
///   LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib \
///   flutter test test/tools/maia_policy.dart \
///     --dart-define=FEN="rnbqkb1r/3p1ppp/P3pn2/2pP4/8/8/PP2PPPP/RNBQKBNR w KQkq - 0 6"
library;

import 'dart:io';

import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show uciToSan;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fen = String.fromEnvironment('FEN');
const _elo = int.fromEnvironment('ELO', defaultValue: 2200);

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.support);
  final String support;
  @override
  Future<String?> getApplicationDocumentsPath() async => support;
  @override
  Future<String?> getApplicationSupportPath() async => support;
}

void main() {
  test('maia policy', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    PathProviderPlatform.instance = _Paths(
      p.join(
        Platform.environment['HOME']!,
        '.local',
        'share',
        'com.example.chess_auto_prep',
      ),
    );

    expect(MaiaFactory.isAvailable, isTrue, reason: 'Maia not available here');
    await MaiaFactory.instance!.initialize();
    final result = await MaiaFactory.instance!.evaluate(_fen, _elo);
    expect(
      result.policy,
      isNotEmpty,
      reason: 'empty policy — model not loaded',
    );

    final sorted = result.policy.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    stdout.writeln('Maia $_elo on $_fen');
    stdout.writeln('${sorted.length} policy entries; top 12:');
    var cumulative = 0.0;
    for (final e in sorted.take(12)) {
      cumulative += e.value;
      final san = uciToSan(_fen, e.key);
      stdout.writeln(
        '  ${san.padRight(7)} ${(100 * e.value).toStringAsFixed(2).padLeft(6)}%'
        '   cumulative ${(100 * cumulative).toStringAsFixed(1)}%'
        '${e.value >= 0.05 ? '   <- above the 5% coverage floor' : ''}',
      );
    }
    final above = sorted.where((e) => e.value >= 0.05).length;
    stdout.writeln('moves at or above the 5% floor: $above');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
