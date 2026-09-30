import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';

/// One place the app keeps things on disk. [removable] stores are derived
/// data the app can rebuild or download again; nothing the user wrote is
/// ever [removable].
typedef StoreUsage = ({String name, String path, int bytes, bool removable});

/// A store the app keeps: a SQLite file (measured with its sidecars) or a
/// folder (measured recursively, links not followed).
typedef KeptStore = ({String name, String path, bool removable});

/// Where the app keeps things: what to measure, the support folder, and the
/// derived databases whose leftovers may be deleted.
typedef StoragePlaces = ({
  List<KeptStore> stores,
  String support,
  List<String> derived,
});

const _sidecars = ['', '-wal', '-shm', '-journal'];

/// Copies an upgrade or a failed open left beside a derived database:
/// `master_games.db.pre-v3.bak`, `master_games.db.unreadable-20260928T101500`.
/// Only names built on [derived] databases qualify, so a user's file or a
/// recovery record is never offered for deletion.
bool isLeftover(String name, Iterable<String> derived) => derived.any(
  (base) =>
      name.startsWith('$base.') &&
      RegExp(
        r'\.(bak|unreadable-[0-9T]+)(-wal|-shm|-journal)?$',
      ).hasMatch(name),
);

/// Measures [stores] and the leftovers of [derived] databases in [support].
/// Runs off the UI isolate and never throws: a store that cannot be read
/// measures 0 and a vanished drive is simply absent.
Future<List<StoreUsage>> measureStorage(
  List<KeptStore> stores, {
  required String support,
  required List<String> derived,
}) => Isolate.run(
  () => [
    for (final store in stores)
      (
        name: store.name,
        path: store.path,
        bytes: _bytes(store.path),
        removable: store.removable,
      ),
    for (final name in _leftovers(support, derived))
      (
        name: 'Leftover $name',
        path: p.join(support, name),
        bytes: _bytes(p.join(support, name)),
        removable: true,
      ),
  ],
);

/// Leftover databases in [support], each once (its sidecars measure with
/// it). A missing support folder has none.
List<String> _leftovers(String support, List<String> derived) {
  try {
    return Directory(support)
        .listSync(followLinks: false)
        .whereType<File>()
        .map((file) => p.basename(file.path))
        .where((name) => isLeftover(name, derived))
        .where(
          (name) => !_sidecars.any((s) => s.isNotEmpty && name.endsWith(s)),
        )
        .toList()
      ..sort();
  } on FileSystemException {
    return const [];
  }
}

int _bytes(String path) {
  try {
    return switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      FileSystemEntityType.file => _sidecars.fold(
        0,
        (sum, suffix) => sum + _length(File('$path$suffix')),
      ),
      FileSystemEntityType.directory =>
        Directory(path)
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .fold(0, (sum, file) => sum + _length(file)),
      _ => 0,
    };
  } on FileSystemException {
    return 0;
  }
}

/// A file removed while it was being measured measures nothing.
int _length(File file) {
  try {
    return file.lengthSync();
  } on FileSystemException {
    return 0;
  }
}

/// Deletes a derived database with its sidecars, so the space is actually
/// freed; answers why it could not, or null. Readers open and close their
/// own connections per query, so a Windows sharing violation is transient:
/// it is retried for a short while and then reported, never ignored.
Future<String?> deleteDerivedFile(String path) async {
  for (final suffix in _sidecars.reversed) {
    final problem = await _delete(File('$path$suffix'));
    if (problem != null) return problem;
  }
  return null;
}

Future<String?> _delete(File file) async {
  for (var attempt = 0; ; attempt++) {
    try {
      if (await file.exists()) await file.delete();
      return null;
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      final busy = Platform.isWindows && const [5, 32, 33].contains(code);
      if (!busy || attempt >= 20) {
        log.w('delete ${file.path}', error);
        return error.osError?.message ?? error.message;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// A human size: `0 B`, `812 KB`, `3.1 GB`.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
