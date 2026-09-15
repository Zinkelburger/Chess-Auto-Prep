/// Smoothed throughput of a long transfer, sampled once per tick.
///
/// A per-second sample of a multi-hour download is far too jumpy to show
/// as-is, so the rate is an exponential moving average of the samples.
library;

/// Longest ETA worth reporting; anything beyond it means the rate is noise.
const Duration _maxEta = Duration(days: 90);

class TransferRateMeter {
  /// Weight of the newest sample in the moving average.
  static const double _newSampleWeight = 0.3;

  double _bytesPerSecond = 0;
  int _lastSampleBytes = 0;

  /// Smoothed bytes per tick, 0 until the first sample after [reset].
  double get bytesPerSecond => _bytesPerSecond;

  /// Forget the rate and start counting from [bytesDone].
  void reset(int bytesDone) {
    _bytesPerSecond = 0;
    _lastSampleBytes = bytesDone;
  }

  /// Fold the bytes transferred since the previous sample into the rate.
  /// Call once per tick with the running total.
  void sample(int bytesDone) {
    final delta = bytesDone - _lastSampleBytes;
    _lastSampleBytes = bytesDone;
    _bytesPerSecond = _bytesPerSecond == 0
        ? delta.toDouble()
        : _bytesPerSecond * (1 - _newSampleWeight) + delta * _newSampleWeight;
  }

  /// Time to transfer [remainingBytes] at the current rate, or null before a
  /// rate is known, once nothing remains, or when the answer is absurd.
  Duration? eta(int remainingBytes) {
    if (_bytesPerSecond <= 0 || remainingBytes <= 0) return null;
    final seconds = remainingBytes / _bytesPerSecond;
    if (!seconds.isFinite || seconds > _maxEta.inSeconds) return null;
    return Duration(seconds: seconds.round());
  }
}
