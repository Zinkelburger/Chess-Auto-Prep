import 'dart:io';

import 'package:chess_auto_prep/app_version.dart';
import 'package:flutter_test/flutter_test.dart';

/// A version constant nobody keeps up to date is worse than none: it makes a
/// bug report name a build that is not the one that failed.
void main() {
  test('kAppVersion is the version in pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsLinesSync();
    final line = pubspec.firstWhere((l) => l.startsWith('version:'));
    // pubspec allows "1.2.3+4"; the build number is not part of what we show.
    final declared = line.split(':')[1].trim().split('+').first;
    expect(
      kAppVersion,
      declared,
      reason: 'lib/app_version.dart is out of step with pubspec.yaml',
    );
  });
}
