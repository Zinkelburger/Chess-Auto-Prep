import 'package:chess_auto_prep/utils/piecewise_linear.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const anchors = <(num, num)>[(600, 0.12), (1000, 0.08), (1400, 0.05)];

  test('returns an anchor value exactly on the anchor', () {
    expect(interpolatePiecewiseLinear(anchors, 600), 0.12);
    expect(interpolatePiecewiseLinear(anchors, 1000), 0.08);
    expect(interpolatePiecewiseLinear(anchors, 1400), 0.05);
  });

  test('interpolates linearly between anchors', () {
    expect(interpolatePiecewiseLinear(anchors, 800), closeTo(0.10, 1e-12));
    expect(interpolatePiecewiseLinear(anchors, 1300), closeTo(0.0575, 1e-12));
  });

  test('clamps to the endpoints outside the table', () {
    expect(interpolatePiecewiseLinear(anchors, 0), 0.12);
    expect(interpolatePiecewiseLinear(anchors, 5000), 0.05);
  });

  test('accepts integer tables and reads through as doubles', () {
    const ints = <(int, int)>[(100, 1000), (200, 1400)];
    expect(interpolatePiecewiseLinear(ints, 150), 1200.0);
    expect(interpolatePiecewiseLinear(ints, 200), 1400.0);
  });
}
