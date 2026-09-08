import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'invalid image preserves signed/unsigned status without a diagnosis',
    () {
      for (final code in [-1073741701, 0xC000007B]) {
        final text = BughouseEngine.describeExit(code, isWindows: true);
        expect(
          text,
          contains('$code; 0xC000007B; STATUS_INVALID_IMAGE_FORMAT'),
        );
        expect(text, isNot(contains('damaged')));
        expect(text, isNot(contains('replaced')));
      }
    },
  );

  test('Windows status names distinguish loader failures', () {
    for (final entry in {
      0xC0000135: 'STATUS_DLL_NOT_FOUND',
      0xC0000139: 'STATUS_ENTRYPOINT_NOT_FOUND',
      0xC0000142: 'STATUS_DLL_INIT_FAILED',
      0xC000001D: 'STATUS_ILLEGAL_INSTRUCTION',
    }.entries) {
      expect(BughouseEngine.describeExit(entry.key), contains(entry.value));
    }
    expect(
      BughouseEngine.describeExit(-1073741515, isWindows: false),
      contains('STATUS_DLL_NOT_FOUND'),
    );
    expect(
      BughouseEngine.describeExit(127, isWindows: true),
      'Engine exited (127; 0x0000007F)',
    );
  });

  test('Unix codes and signals stay factual', () {
    expect(
      BughouseEngine.describeExit(127, isWindows: false),
      'Engine exited (127)',
    );
    expect(
      BughouseEngine.describeExit(-9, isWindows: false),
      'Engine exited (-9; SIGKILL)',
    );
    expect(
      BughouseEngine.describeExit(-4, isWindows: false),
      'Engine exited (-4; SIGILL)',
    );
  });

  test('timeout preserves engine output without guessing at a missing DLL', () {
    final text = BughouseEngine.stalledMessage(
      what: 'uci',
      timeout: const Duration(seconds: 90),
      spoke: false,
      stderr: const ['LoadLibrary failed: example.dll'],
      isWindows: true,
    );
    expect(text, contains('within 90s'));
    expect(text, contains('No stdout received'));
    expect(text, contains('LoadLibrary failed: example.dll'));
    expect(text, isNot(contains('Visual C++')));
  });
}
