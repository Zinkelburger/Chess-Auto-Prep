/// Counts as people read them.
library;

/// `1234567` → `1,234,567`. Negative values keep their sign.
String formatThousands(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer();
  if (value < 0) buffer.write('-');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
