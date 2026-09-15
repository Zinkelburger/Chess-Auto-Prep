import 'package:chess_auto_prep/services/eval/transfer_rate_meter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the first sample sets the rate outright', () {
    final meter = TransferRateMeter()..reset(1000);
    expect(meter.bytesPerSecond, 0);
    expect(meter.eta(5000), isNull, reason: 'no rate yet');

    meter.sample(1500);
    expect(meter.bytesPerSecond, 500);
  });

  test('later samples are smoothed towards the newest delta', () {
    final meter = TransferRateMeter()
      ..reset(0)
      ..sample(1000)
      ..sample(1000);
    // 1000 * 0.7 + 0 * 0.3
    expect(meter.bytesPerSecond, closeTo(700, 1e-9));
    meter.sample(2000);
    expect(meter.bytesPerSecond, closeTo(700 * 0.7 + 1000 * 0.3, 1e-9));
  });

  test('eta divides what is left by the rate', () {
    final meter = TransferRateMeter()
      ..reset(0)
      ..sample(250);
    expect(meter.eta(1000), const Duration(seconds: 4));
    expect(meter.eta(0), isNull);
    expect(meter.eta(-5), isNull);
  });

  test('an eta past 90 days is reported as unknown', () {
    final meter = TransferRateMeter()
      ..reset(0)
      ..sample(1);
    expect(meter.eta(100 * 24 * 60 * 60), isNull);
    expect(meter.eta(60), const Duration(minutes: 1));
  });

  test('reset forgets the rate', () {
    final meter = TransferRateMeter()
      ..reset(0)
      ..sample(800)
      ..reset(800);
    expect(meter.bytesPerSecond, 0);
    meter.sample(900);
    expect(meter.bytesPerSecond, 100, reason: 'counts from the reset total');
  });
}
