/// Where a record the app cannot understand or finish goes: aside, whole, into
/// `Support/recovery-quarantine/<time>/`, with a line in the app log. The
/// record may hold the only copy of someone's edit, so it is never deleted;
/// it only stops being something every open and save has to get past.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';

/// The folder under Support that set-aside records are moved into.
const quarantineFolder = 'recovery-quarantine';

/// Moves [entry] into the quarantine folder under [support] and logs [reason].
/// A failure to move it is logged too, and answered false; the caller carries
/// on either way.
Future<bool> quarantine(
  Directory support,
  FileSystemEntity entry,
  Object reason,
) async {
  final folder = _folder(support);
  final target = p.join(
    folder.path,
    '${p.basename(p.dirname(entry.path))}-${p.basename(entry.path)}',
  );
  try {
    await folder.create(recursive: true);
    await entry.rename(target);
    log.w('set aside ${entry.path} at $target', reason);
    return true;
  } on FileSystemException catch (error) {
    log.e('set aside ${entry.path} ($reason)', error);
    return false;
  }
}

/// Keeps a copy of [bytes] as [name] in a new quarantine folder under
/// [support] and logs [reason]; the original stays where it is. A failure to
/// copy is logged too, and the caller carries on either way.
Future<void> quarantineCopy(
  Directory support,
  String name,
  List<int> bytes,
  Object reason,
) async {
  final target = File(p.join(_folder(support).path, name));
  try {
    // Claim the name first, so a copy is never written over another.
    await target.create(recursive: true, exclusive: true);
    await replaceFile(target.path, bytes);
    log.w('kept a copy of $name at ${target.path}', reason);
  } on Object catch (error) {
    log.e('keep a copy of $name ($reason)', error);
  }
}

Directory _folder(Directory support) {
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
    RegExp('[-:.]'),
    '',
  );
  return Directory(p.join(support.path, quarantineFolder, stamp));
}
