// The profile each fault case runs on: seeded once, then copied back before
// every case at the same path, since the training files name chapters by
// absolute path, so every case starts from the same bytes.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'profile.dart';

final class ProfileWorkspace {
  ProfileWorkspace._(this._folder, this.live);

  final Directory _folder;

  /// The profile every case runs on.
  final Profile live;

  Directory get _template => Directory(p.join(_folder.path, 'template'));

  /// A workspace whose profile [seed] filled, with plain dart:io. What
  /// [seed] writes beside the profile (a download outside it, say) stays
  /// there for every case.
  static Future<ProfileWorkspace> seeded(
    Future<void> Function(Profile profile) seed,
  ) async {
    final folder = await Directory.systemTemp.createTemp('v2-fault-matrix-');
    final live = Profile(p.join(folder.path, 'live'));
    await Directory(live.documents).create(recursive: true);
    await Directory(live.support).create(recursive: true);
    await seed(live);
    final workspace = ProfileWorkspace._(folder, live);
    _copy(Directory(live.root), workspace._template);
    return workspace;
  }

  /// The seeded profile again, whatever the last case left.
  Future<Profile> fresh() async {
    final root = Directory(live.root);
    if (root.existsSync()) root.deleteSync(recursive: true);
    _copy(_template, root);
    return live;
  }

  Future<void> dispose() => _folder.delete(recursive: true);
}

/// Copies [from] into [to] in name order, so a listing of the copy comes
/// back in the same order every time.
void _copy(Directory from, Directory to) {
  to.createSync(recursive: true);
  final entries = from.listSync(followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries) {
    final target = p.join(to.path, p.basename(entry.path));
    switch (entry) {
      case Directory():
        _copy(entry, Directory(target));
      case File():
        entry.copySync(target);
      case Link():
        Link(target).createSync(entry.targetSync());
    }
  }
}
