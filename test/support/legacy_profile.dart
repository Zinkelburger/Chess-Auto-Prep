import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Profiles in the existing on-disk format: for each named scenario, every
/// entry written under a disposable profile (Documents/ and Support/),
/// recorded once. `{profile}` in a file stands for the profile's path.
const _receipts = 'test/fixtures/legacy/v1_repertoire_receipts.json';

/// Writes the entries recorded for [scenario] into [profile].
Future<void> restoreLegacyProfile(Directory profile, String scenario) async {
  final all =
      jsonDecode(await File(_receipts).readAsString()) as Map<String, Object?>;
  final entries = all[scenario] as Map<String, Object?>?;
  if (entries == null) throw ArgumentError.value(scenario, 'scenario');
  // Parents sort before their children.
  for (final MapEntry(:key, :value) in entries.entries) {
    final path = p.joinAll([profile.path, ...p.posix.split(key)]);
    final entry = value! as Map<String, Object?>;
    if (entry['directory'] == true) {
      await Directory(path).create(recursive: true);
    } else if (entry['link'] case final String target) {
      await Link(path).create(target);
    } else {
      await File(path).writeAsString(
        (entry['text']! as String).replaceAll('{profile}', profile.path),
      );
    }
  }
}
