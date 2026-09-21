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
