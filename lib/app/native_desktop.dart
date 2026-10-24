import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../diagnostics/log.dart';
import '../features/settings/app_updates.dart';
import '../net/github_releases.dart';
import '../storage/update_files.dart';
import '../storage/update_install.dart';

/// Updates from GitHub into `<cache>/updates`. A development build checks
/// only when asked, unless `CHESS_AUTO_PREP_RELEASES_URL` points it at a
/// local release fixture for a headless check of the prompt.
UpdateOutside nativeUpdates(http.Client client, Directory cache) {
  final fixture = Platform.environment['CHESS_AUTO_PREP_RELEASES_URL'];
  final folder = UpdateFolder(Directory(p.join(cache.path, 'updates')));
  return (
    releases: GitHubReleases(
      client,
      latestUrl: fixture == null ? null : Uri.parse(fixture),
    ),
    folder: folder,
    installer: UpdateInstaller(readHelper: rootBundle.loadString),
    version: () async => (await PackageInfo.fromPlatform()).version,
    automatic: kReleaseMode || fixture != null,
    openPage: openInBrowser,
    showFolder: (path) => unawaited(openFolder(Directory(path))),
  );
}

/// The window in or out of full screen. The window plugin wants its
/// handshake before the first call; it is cheap and harmless to repeat.
Future<void> setWindowFullScreen(bool on) async {
  await windowManager.ensureInitialized();
  await windowManager.setFullScreen(on);
}

/// Shows [folder] in the desktop's file manager. A desktop that will not
/// open it is the desktop's failure; the user saw nothing happen, and the
/// log says why.
Future<void> openFolder(Directory folder) async {
  try {
    await folder.create(recursive: true);
    final opened = await launchUrl(Uri.directory(folder.path));
    if (!opened) log.w('open ${folder.path}', 'the desktop declined');
  } on Object catch (error) {
    log.w('open ${folder.path}', error);
  }
}

/// Sends [page] to the desktop's browser and says whether it went. The
/// caller shows the link when it did not; the log says why.
Future<bool> openInBrowser(Uri page) async {
  try {
    final opened = await launchUrl(page, mode: LaunchMode.externalApplication);
    if (!opened) {
      log.w('open ${page.host} in the browser', 'the desktop declined');
    }
    return opened;
  } on Object catch (error) {
    log.w('open ${page.host} in the browser', error);
    return false;
  }
}
