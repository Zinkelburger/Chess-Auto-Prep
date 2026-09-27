/// Where a record the app cannot understand or finish goes: aside, whole, into
/// `Support/recovery-quarantine/<time>/`, with a line in the app log. The
/// record may hold the only copy of someone's edit, so it is never deleted;
/// it only stops being something every open and save has to get past.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';

/// The folder under Support that set-aside records are moved into.
const quarantineFolder = 'recovery-quarantine';

/// Moves [entry] into the quarantine folder under [support] and logs [reason].
/// A failure to move it is logged too; the caller carries on either way.
Future<void> quarantine(
  Directory support,
  FileSystemEntity entry,
  Object reason,
) async {
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
    RegExp('[-:.]'),
    '',
  );
  final folder = Directory(p.join(support.path, quarantineFolder, stamp));
  final target = p.join(
    folder.path,
    '${p.basename(p.dirname(entry.path))}-${p.basename(entry.path)}',
  );
  try {
    await folder.create(recursive: true);
    await entry.rename(target);
    log.w('set aside ${entry.path} at $target', reason);
  } on FileSystemException catch (error) {
    log.e('set aside ${entry.path} ($reason)', error);
  }
}
