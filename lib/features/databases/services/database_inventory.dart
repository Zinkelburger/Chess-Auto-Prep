/// What the app is actually keeping on this machine, measured rather than
/// assumed.
///
/// Every store used to report its own size and nobody reported the total, so
/// the number a user saw was always smaller than the number their disk saw.
/// On the machine this was written against the master-games section said
/// 2.1 GB while its directory held 4.0 GB: `master_games.db.pre-v3.bak`, left
/// behind by a schema migration, is 1.9 GB that no code in `lib/` has
/// referenced since. Nothing in the UI could ever have shown it, because
/// every panel measured the one file it knew the name of.
///
/// So this walks the directories instead. Three rules it keeps to:
///
///   * **A store is a set of files, not a file.** SQLite writes `-wal` and
///     `-shm` beside its database and both count against the disk, so
///     [StoreFootprint] sums a stem and its sidecars.
///   * **Anything not claimed is a leftover, not an error.** [strays] is
///     whatever is left in a directory once every known store has taken its
///     files. A stray is reported, never deleted on its own.
///   * **Measuring is read-only and must not throw.** A directory the user
///     moved, a permission they revoked, a store on a drive that is not
///     mounted today: each is a missing row, not a crash on a page whose
///     whole job is to say what is missing.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../services/storage/file_mutation_service.dart';

/// One store's files and what they weigh.
class StoreFootprint {
  const StoreFootprint({
    required this.label,
    required this.bytes,
    required this.paths,
  });

  final String label;

  /// Total of every file in [paths] that exists.
  final int bytes;

  /// Absolute paths counted, sidecars included.
  final List<String> paths;

  bool get exists => paths.isNotEmpty;
}

/// A file inside a directory the app owns that no store claims.
class StrayFile {
  const StrayFile({required this.path, required this.bytes, this.reason});

  final String path;
  final int bytes;

  /// Why we think it is safe to remove, in the user's words — shown next to
  /// the size, because "delete a 1.9 GB file you have never heard of" needs a
  /// sentence more than a checkbox does.
  final String? reason;

  String get name => p.basename(path);
}

/// Everything measured in one pass.
class DatabaseInventory {
  const DatabaseInventory({
    required this.stores,
    required this.strays,
    required this.directories,
    this.quarantineBytes = 0,
  });

  const DatabaseInventory.empty()
    : stores = const [],
      strays = const [],
      directories = const [],
      quarantineBytes = 0;

  final List<StoreFootprint> stores;
  final List<StrayFile> strays;

  /// The directories walked, for "open folder" and for saying where things
  /// live without making the user guess.
  final List<String> directories;

  /// What is sitting in `.trash`, waiting to be emptied.
  ///
  /// [deleteStrayFile] renames rather than unlinks, so "delete" on this page
  /// is recoverable — and frees nothing at all until [emptyQuarantine] runs.
  /// A page whose entire purpose is to report disk use may not quietly stop
  /// counting bytes that are still on the disk, so this is measured and shown
  /// like any other row.
  final int quarantineBytes;

  int get storeBytes => stores.fold(0, (a, s) => a + s.bytes);
  int get strayBytes => strays.fold(0, (a, s) => a + s.bytes);
  int get totalBytes => storeBytes + strayBytes + quarantineBytes;

  StoreFootprint? operator [](String label) {
    for (final s in stores) {
      if (s.label == label) return s;
    }
    return null;
  }
}

/// Labels [DatabaseInventory] keys its stores by. Constants rather than
/// strings at the call site so a typo is a compile error and the Databases
/// page and this file cannot drift apart.
abstract final class StoreLabels {
  static const masterGames = 'master-games';
  static const yourGames = 'your-games';
  static const evalCache = 'eval-cache';
  static const bughouseBook = 'bughouse-book';
  static const lichessEvals = 'lichess-evals';
  static const chessDbDump = 'chessdb-dump';
}

/// Reads the sizes of everything the app keeps.
///
/// [supportDirectory] is the app's own data directory; [bughouseBookPath] and
/// the two eval paths are wherever those stores were configured to live,
/// which is routinely a different drive. Pass null for one that is not set up.
Future<DatabaseInventory> readDatabaseInventory({
  required String supportDirectory,
  String? bughouseBookPath,
  String? lichessEvalsPath,
  String? chessDbDataDirectory,
}) async {
  final stores = <StoreFootprint>[];
  final directories = <String>[];
  final claimed = <String>{};

  void addDirectory(String? dir) {
    if (dir == null || dir.isEmpty) return;
    if (directories.contains(dir)) return;
    if (!Directory(dir).existsSync()) return;
    directories.add(dir);
  }

  /// A database and the `-wal`/`-shm` SQLite writes beside it.
  StoreFootprint sqliteStore(String label, String path) {
    final paths = <String>[];
    var bytes = 0;
    for (final candidate in [path, '$path-wal', '$path-shm']) {
      final size = _fileBytes(candidate);
      if (size == null) continue;
      paths.add(candidate);
      bytes += size;
      claimed.add(candidate);
    }
    return StoreFootprint(label: label, bytes: bytes, paths: paths);
  }

  addDirectory(supportDirectory);
  stores.add(
    sqliteStore(
      StoreLabels.masterGames,
      p.join(supportDirectory, 'master_games.db'),
    ),
  );
  stores.add(
    sqliteStore(
      StoreLabels.yourGames,
      p.join(supportDirectory, 'app_games.db'),
    ),
  );
  stores.add(
    sqliteStore(
      StoreLabels.evalCache,
      p.join(supportDirectory, 'eval_cache.db'),
    ),
  );

  if (bughouseBookPath != null && bughouseBookPath.isNotEmpty) {
    addDirectory(p.dirname(bughouseBookPath));
    stores.add(sqliteStore(StoreLabels.bughouseBook, bughouseBookPath));
  }
  if (lichessEvalsPath != null && lichessEvalsPath.isNotEmpty) {
    addDirectory(lichessEvalsPath);
    stores.add(
      StoreFootprint(
        label: StoreLabels.lichessEvals,
        bytes: await _directoryBytes(lichessEvalsPath),
        paths: [lichessEvalsPath],
      ),
    );
  }
  if (chessDbDataDirectory != null && chessDbDataDirectory.isNotEmpty) {
    addDirectory(chessDbDataDirectory);
    stores.add(
      StoreFootprint(
        label: StoreLabels.chessDbDump,
        bytes: await _directoryBytes(chessDbDataDirectory),
        paths: [chessDbDataDirectory],
      ),
    );
  }

  return DatabaseInventory(
    stores: stores.where((s) => s.exists).toList(),
    strays: await _straysIn(supportDirectory, claimed),
    directories: directories,
    quarantineBytes: await _directoryBytes(quarantineDirFor(supportDirectory)),
  );
}

/// Where [deleteStrayFile] puts what it removes.
String quarantineDirFor(String directory) => p.join(directory, '.trash');

/// Unlinks the quarantine for real, and reports what that freed.
///
/// The counterpart to [deleteStrayFile]'s rename. Two steps rather than one
/// because a mistaken delete of a two-gigabyte database is expensive to undo
/// and cheap to prevent — but the second step has to exist and has to be
/// reachable, or "delete" on the Databases page never frees a byte.
Future<int> emptyQuarantine(String supportDirectory) async {
  final dir = Directory(quarantineDirFor(supportDirectory));
  if (!dir.existsSync()) return 0;
  final freed = await _directoryBytes(dir.path);
  try {
    await FileMutationService.instance.deleteDisposableDirectory(
      dir,
      allowedRoot: Directory(supportDirectory),
    );
  } on FileSystemException {
    return 0;
  }
  return freed;
}

/// Files directly inside [directory] that no store claimed.
///
/// Only the top level, and only files: the subdirectories in there belong to
/// bundled engines and networks that the app extracts on demand and can
/// re-extract, which is a different conversation from "you have a spare copy
/// of a two-gigabyte database".
Future<List<StrayFile>> _straysIn(String directory, Set<String> claimed) async {
  final dir = Directory(directory);
  if (!dir.existsSync()) return const [];
  final strays = <StrayFile>[];
  try {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      if (claimed.contains(entity.path)) continue;
      final name = p.basename(entity.path);
      final reason = _strayReason(name);
      if (reason == null) continue;
      final size = _fileBytes(entity.path);
      if (size == null || size == 0) continue;
      strays.add(StrayFile(path: entity.path, bytes: size, reason: reason));
    }
  } on FileSystemException {
    return const [];
  }
  strays.sort((a, b) => b.bytes.compareTo(a.bytes));
  return strays;
}

/// Why a file is offered for deletion, or null to leave it alone.
///
/// Deliberately a allowlist of shapes we put there ourselves. Settings,
/// preferences and anything we do not recognise are not "leftovers" just
/// because this file has not heard of them — the page would then invite a
/// user to delete their own configuration.
String? _strayReason(String name) {
  if (name.endsWith('.bak') || name.contains('.pre-v')) {
    return 'A copy kept by an upgrade. The current database replaced it.';
  }
  if (name.endsWith('.db-journal') || name.endsWith('.tmp')) {
    return 'Left behind by an interrupted write.';
  }
  return null;
}

/// Removes one leftover, and says whether it went.
///
/// Only ever called with a [StrayFile] this file produced, which is to say a
/// path that matched [_strayReason] on a directory the app owns. It re-checks
/// the name rather than trusting the argument: a delete driven by a list that
/// was measured minutes ago, on a page whose whole subject is multi-gigabyte
/// databases, is worth one more look.
Future<bool> deleteStrayFile(StrayFile stray) async {
  if (_strayReason(p.basename(stray.path)) == null) return false;
  try {
    final file = File(stray.path);
    if (!file.existsSync()) return true;
    final parent = file.parent;
    await FileMutationService.instance.quarantineFile(
      file,
      allowedRoot: parent,
      quarantineRoot: Directory(p.join(parent.path, '.trash')),
    );
    return true;
  } on FileSystemException {
    return false;
  }
}

int? _fileBytes(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.lengthSync();
  } on FileSystemException {
    return null;
  }
}

Future<int> _directoryBytes(String path) async {
  final dir = Directory(path);
  if (!dir.existsSync()) return 0;
  var total = 0;
  try {
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      total += _fileBytes(entity.path) ?? 0;
    }
  } on FileSystemException {
    return total;
  }
  return total;
}
