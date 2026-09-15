/// Piecewise-linear interpolation over a sorted anchor table.
///
/// The one shape behind every empirical lookup curve in the app (rating
/// conversions, findability bars): straight lines between measured points,
/// clamped to the first and last point outside the measured range rather
/// than extrapolated.
library;

/// The value of the curve through [anchors] at [x].
///
/// [anchors] are `(x, y)` pairs in ascending `x` and must not be empty.
/// Outside `[anchors.first.x, anchors.last.x]` the nearest endpoint's `y`
/// is returned; on an anchor the anchor's own `y` is returned exactly.
double interpolatePiecewiseLinear(List<(num, num)> anchors, num x) {
  assert(anchors.isNotEmpty, 'an interpolation table needs at least one point');
  final first = anchors.first;
  final last = anchors.last;
  if (x <= first.$1) return first.$2.toDouble();
  if (x >= last.$1) return last.$2.toDouble();
  for (var i = 0; i < anchors.length - 1; i++) {
    final (loX, loY) = anchors[i];
    final (hiX, hiY) = anchors[i + 1];
    if (x < loX || x > hiX) continue;
    if (x == loX) return loY.toDouble();
    if (x == hiX) return hiY.toDouble();
    final t = (x - loX) / (hiX - loX);
    return loY + t * (hiY - loY);
  }
  return last.$2.toDouble();
}
