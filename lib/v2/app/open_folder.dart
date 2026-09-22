import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

import '../diagnostics/log.dart';

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
    if (!opened)
      log.w('open ${page.host} in the browser', 'the desktop declined');
    return opened;
  } on Object catch (error) {
    log.w('open ${page.host} in the browser', error);
    return false;
  }
}
