import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'file_lock.dart';

/// Disposable, fingerprint-keyed engine reports. Failure to read or keep one
/// never blocks access to the source games or their player record.
final class PlayerReports {
  PlayerReports([this.folder]);
  final Directory? folder;
  final _memory = <String, Map<String, Object?>>{};
  String _path(String key) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key))
      throw const FormatException('Invalid report key.');
    return p.join(folder!.path, '$key.json');
  }

  Future<Map<String, Object?>?> read(String key) async {
    if (folder == null) return _memory[key];
    try {
      final file = File(_path(key));
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      return data is Map && data['version'] == 1
          ? Map<String, Object?>.from(data)
          : null;
    } on Object catch (e) {
      log.w('read cached player analysis', e);
      return null;
    }
  }

  Future<void> keep(String key, Map<String, Object?> report) async {
    if (folder == null) {
      _memory[key] = report;
      return;
    }
    try {
      await folder!.create(recursive: true);
      await withDirectoryLock(
        folder!,
        () => replaceFile(_path(key), utf8.encode(jsonEncode(report))),
      );
    } on Object catch (e) {
      log.w('keep cached player analysis', e);
    }
  }
}
