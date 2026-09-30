// A disposable profile by its paths alone, so a test can hand it to another
// isolate: the Documents and Support pair every v2 store is built on.
import 'dart:io';

import 'package:path/path.dart' as p;

final class Profile {
  const Profile(this.root);

  /// Holds `Documents/` and `Support/`; snapshots name entries from here.
  final String root;

  String get documents => p.join(root, 'Documents');
  String get support => p.join(root, 'Support');
  String get repertoires => p.join(documents, 'repertoires');
  String get studies => p.join(documents, 'studies');
  String get gamesLibrary => p.join(documents, 'games_library');
  String get books => p.join(support, 'books.json');
  String get settings => p.join(support, 'settings.json');

  /// [relative] under Documents, written with `/`.
  String document(String relative) =>
      p.joinAll([documents, ...p.posix.split(relative)]);

  /// [relative] under Support, written with `/`.
  String supportFile(String relative) =>
      p.joinAll([support, ...p.posix.split(relative)]);

  /// A training file, which both apps keep at the top of Documents.
  String training(String name) => p.join(documents, name);

  /// An empty profile in the system temporary folder, never the user's.
  static Future<Profile> temporary() async {
    final root = await Directory.systemTemp.createTemp('v2-profile-');
    final profile = Profile(root.path);
    await Directory(profile.documents).create();
    await Directory(profile.support).create();
    return profile;
  }

  Future<void> dispose() => Directory(root).delete(recursive: true);
}
