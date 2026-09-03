import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the app says when the engine does not work.
///
/// This is the code path a user on another machine actually meets, and it was
/// the least informative part of the feature: a friend on Windows saw
/// "Engine did not answer uci within 90s" with nothing after it, which was
/// true and useless. The engine had been stopped by the Windows loader over a
/// missing Visual C++ runtime DLL, so it never printed a line and never
/// exited. Both readings below exist to name that, and the numbers are the
/// NTSTATUS values Windows actually reports.
void main() {
  group('describeExit', () {
    test('names a missing library instead of a negative number', () {
      const message = 'Redistributable';
      expect(BughouseEngine.describeExit(0xC0000135), contains(message));
      // Dart hands the same status back signed on some paths.
      expect(BughouseEngine.describeExit(-1073741515), contains(message));
    });

    test('tells an old CPU apart from a missing library', () {
      expect(
        BughouseEngine.describeExit(0xC000001D),
        contains('does not support an instruction'),
      );
      expect(
        BughouseEngine.describeExit(0xC000007B),
        contains('wrong architecture'),
      );
    });

    test('an ordinary exit stays an ordinary exit', () {
      expect(BughouseEngine.describeExit(1), 'Engine exited (1)');
      expect(BughouseEngine.describeExit(0), 'Engine exited (0)');
    });
  });

  group('stalledMessage', () {
    String message({
      bool spoke = true,
      List<String> stderr = const [],
      bool isWindows = false,
    }) => BughouseEngine.stalledMessage(
      what: 'uci',
      timeout: const Duration(seconds: 90),
      spoke: spoke,
      stderr: stderr,
      isWindows: isWindows,
    );

    test('quotes the engine when the engine said why', () {
      expect(
        message(stderr: const ['Error: ONNX model not found: /x.onnx']),
        contains('ONNX model not found'),
      );
    });

    test('a silent process is reported as silent, not as slow', () {
      // Hivemind prints its banner before it opens the network, so nothing at
      // all on stdout means it never reached main — "loading the network" is
      // the one thing that is definitely not happening.
      final text = message(spoke: false);
      expect(text, contains('printed nothing at all'));
      expect(text, contains('never got as far as loading the network'));
    });

    test('on Windows a silent process names the likely cause', () {
      expect(message(spoke: false, isWindows: true), contains('Visual C++'));
      expect(message(spoke: false, isWindows: true), contains('error box'));
    });

    test('a talking engine gets no missing-library guess', () {
      // It loaded and is merely slow, or wedged; blaming a DLL would send the
      // user off installing something they already have.
      expect(
        message(spoke: true, isWindows: true),
        isNot(contains('Visual C++')),
      );
      expect(message(spoke: true), contains('within 90s'));
    });
  });
}
