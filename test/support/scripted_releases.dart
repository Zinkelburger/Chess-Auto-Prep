import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:chess_auto_prep/features/settings/app_updates.dart';
import 'package:chess_auto_prep/net/github_releases.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/storage/update_files.dart';
import 'package:chess_auto_prep/storage/update_install.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// The bytes the scripted release publishes, and their digest.
const releaseBytes = [1, 2, 3, 4, 5];
final releaseDigest = 'sha256:${sha256.convert(releaseBytes)}';

/// GitHub's JSON for release [tag], carrying one file for each [suffixes].
Map<String, Object?> releaseJson({
  String tag = 'v1.17.0',
  List<String> suffixes = const ['linux.zip'],
  bool draft = false,
  bool prerelease = false,
  String? digest,
  int? size,
  String state = 'uploaded',
  String? url,
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'body': 'Notes',
  'assets': [
    for (final suffix in suffixes)
      {
        'name': 'chess-auto-prep-$tag-$suffix',
        'state': state,
        'size': size ?? releaseBytes.length,
        'digest': digest ?? releaseDigest,
        'browser_download_url':
            url ??
            'https://github.com/$updateRepository/releases/download/$tag/'
                'chess-auto-prep-$tag-$suffix',
      },
  ],
};

/// GitHub as a test sets it: what the next check answers and what a
/// download streams. Counts both.
class ScriptedReleases implements AppReleases {
  ReleaseCheck answer = LatestRelease(parseRelease(releaseJson()));
  List<int> bytes = releaseBytes;

  /// When set, a download's bytes come from here instead, for a transfer
  /// the test holds open.
  Stream<List<int>>? held;

  /// When set, a download waits for it before answering, as a server
  /// that has not sent its headers yet.
  Completer<void>? holdDownload;
  int checks = 0;
  int downloads = 0;

  @override
  Future<ReleaseCheck> latest() async {
    checks++;
    return answer;
  }

  @override
  Future<AssetDownload> download(Uri url) async {
    downloads++;
    await holdDownload?.future;
    if (held case final bytes?) return AssetStream(bytes);
    return AssetStream(Stream.value(bytes), length: bytes.length);
  }
}

/// The helper script as a test plays it. Launching it writes its ready
/// file and holds the install lock, as the real script does; it lets go of
/// both once the armed marker is gone, unless [stops] is false.
final class StandInHelper {
  /// Whether a launch gets as far as writing the ready file.
  bool starts = true;

  /// Whether a running helper notices it was disarmed.
  bool stops = true;
  int launches = 0;
  bool running = false;

  Future<void> launch(List<String> arguments) async {
    launches++;
    if (!starts) return;
    final armed = File(arguments.last);
    final ready = File(p.join(armed.parent.path, helperReadyName))
      ..writeAsStringSync('ready');
    running = true;
    Timer.periodic(const Duration(milliseconds: 5), (timer) {
      if (armed.existsSync() || !stops) return;
      if (ready.existsSync()) ready.deleteSync();
      running = false;
      timer.cancel();
    });
  }

  /// `flock -n` on the install lock fails while a helper holds it.
  Future<ProcessResult?> run(String command, List<String> arguments) async =>
      ProcessResult(0, command == 'flock' && running ? 1 : 0, '', '');
}

/// An installer for a marked portable Linux bundle in [root] whose helper
/// is [helper].
UpdateInstaller portableInstaller(Directory root, {StandInHelper? helper}) {
  final app = Directory(p.join(root.path, 'app'))..createSync(recursive: true);
  File(
    p.join(app.path, UpdateInstaller.portableMarker),
  ).writeAsStringSync('1\n');
  final script = helper ?? StandInHelper();
  return UpdateInstaller(
    readHelper: (_) async => '# helper',
    executable: p.join(app.path, 'chess_auto_prep'),
    environment: const {},
    abi: Abi.linuxX64,
    appPid: 4242,
    run: script.run,
    startDetached: (_, arguments) => script.launch(arguments),
    readyPoll: const Duration(milliseconds: 5),
    readyPolls: 20,
  );
}

/// [AppUpdates] over [releases], downloading into [root]/updates.
AppUpdates scriptedUpdates(
  Directory root, {
  required ScriptedReleases releases,
  required SettingsStore settings,
  UpdateInstaller? installer,
  String version = '1.16.1',
  bool automatic = false,
  List<Uri>? opened,
  List<String>? shown,
  DateTime Function() now = DateTime.now,
  Duration startDelay = Duration.zero,
  Duration poll = const Duration(hours: 1),
}) => AppUpdates(
  (
    releases: releases,
    folder: UpdateFolder(Directory(p.join(root.path, 'updates'))),
    installer: installer ?? portableInstaller(root),
    version: () async => version,
    automatic: automatic,
    openPage: (page) async {
      opened?.add(page);
      return true;
    },
    showFolder: (folder) => shown?.add(folder),
  ),
  settings: settings,
  now: now,
  startDelay: startDelay,
  poll: poll,
);
