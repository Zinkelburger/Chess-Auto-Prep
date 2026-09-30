import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'directory_entries.dart';
import 'recovery_files.dart';

/// How far an unfinished operation got: still changing the files it renames
/// or rewrites whole, or past them, repointing what refers to them.
enum Phase { pivots, references }

/// A record in a journal folder: the folder's name and the record's id.
typedef RecordKey = (String journal, String id);

/// The records a names-only look at the journal folders found, and the
/// folders that could not be listed.
typedef Listing = ({Set<RecordKey> records, Set<String> unlisted});

/// One recorded operation this process could not finish yet.
final class Owed {
  Owed._(this.journal, this.id, {required this.since}) : tried = since;

  final String journal;
  final String id;

  /// When it was first left unfinished in this process.
  final DateTime since;

  /// When it was last tried, and how many times it has been.
  DateTime tried;
  int attempts = 0;

  Phase phase = Phase.pivots;

  /// The canonical files and folders it changes; a folder covers what it
  /// holds.
  Set<String> paths = const {};

  /// Why the last try stopped.
  String detail = '';

  /// Whether a plain save may go ahead over [paths]: only what refers to
  /// them is left to change, and a save cannot undo that.
  bool savesPass = false;

  /// The first three tries are at the next access; then 5 s, doubling to
  /// five minutes, so a lasting problem stops costing every access.
  DateTime get next => attempts <= 3
      ? tried
      : tried.add(Duration(seconds: min(300, 5 << min(attempts - 4, 6))));

  /// Whether [path] is one of [paths], lies in one, or holds one.
  bool covers(String path) => paths.any(
    (owed) =>
        p.equals(owed, path) ||
        p.isWithin(owed, path) ||
        p.isWithin(path, owed),
  );
}

/// What this process owes on one profile: each recorded operation it could
/// not finish yet, what it changes and when it is next tried; when the next
/// pass over every journal is due; and the receipts an exact retry is
/// answered from, through any store of the profile.
///
/// A cache of the journal folders, never a record of its own: what is on
/// disk decides. A record nobody here has looked at makes a pass due, and an
/// owed one that is no longer there is dropped. One ledger per canonical
/// Support folder per process, read and changed only under the profile's
/// domain lock, which every gate of the profile takes.
final class RecoveryLedger {
  RecoveryLedger._(this.support);

  static RecoveryLedger of(Directory support) {
    final canonical = canonicalRecoveryRoot(support);
    return _profiles.putIfAbsent(
      canonical.path,
      () => RecoveryLedger._(canonical),
    );
  }

  static final _profiles = <String, RecoveryLedger>{};

  /// How many finished operations each journal remembers for exact retries.
  static const receiptsKept = 256;

  /// The canonical Support folder the journals are in.
  final Directory support;

  final _owed = <RecordKey, Owed>{};
  final _receipts = <String, LinkedHashMap<String, Object>>{};
  var _seen = <RecordKey>{};
  var _passed = false;
  DateTime? _passWait;
  var _lockFailures = 0;

  Iterable<Owed> get owed => _owed.values;

  Owed? owing(String journal, String id) => _owed[(journal, id)];

  /// The owed operations that change one of [paths], or a folder holding
  /// one, or a file inside one.
  Iterable<Owed> naming(Iterable<String> paths) =>
      _owed.values.where((owed) => paths.any(owed.covers));

  /// The records in [journals], by name only: nothing is read or decoded.
  Future<Listing> list(Iterable<String> journals) async {
    final records = <RecordKey>{};
    final unlisted = <String>{};
    for (final journal in journals) {
      final folder = Directory(p.join(support.path, journal));
      try {
        if (await FileSystemEntity.type(folder.path, followLinks: false) !=
            FileSystemEntityType.directory) {
          continue;
        }
        await for (final entry in directoryEntries(
          folder,
          followLinks: false,
        )) {
          final name = p.basename(entry.path);
          // A record's `.following` and `.aside` markers name the record.
          records.add((
            journal,
            const {'.json', '.following', '.aside'}.contains(p.extension(name))
                ? p.basenameWithoutExtension(name)
                : name,
          ));
        }
      } on FileSystemException {
        unlisted.add(journal);
      }
    }
    return (records: records, unlisted: unlisted);
  }

  /// Drops what is owed but no longer recorded: another process finished
  /// or set it aside. A folder that could not be listed drops nothing.
  void listed(Listing listing) => _owed.removeWhere(
    (key, _) =>
        !listing.unlisted.contains(key.$1) && !listing.records.contains(key),
  );

  /// Whether a pass over every journal is due: none has run yet, a record
  /// nobody here has looked at is there, a folder could not be listed, or an
  /// owed operation is due again. Never while a pass waits
  /// ([passCouldNotRun]).
  bool passDue(DateTime now, Listing listing) =>
      !waiting(now) &&
      (!_passed ||
          listing.unlisted.isNotEmpty ||
          listing.records.any(
            (key) => !_seen.contains(key) && !_owed.containsKey(key),
          ) ||
          _owed.values.any((owed) => !owed.next.isAfter(now)));

  /// Whether a pass that could not run is still waiting its delay. Nothing
  /// is tried meanwhile.
  bool waiting(DateTime now) {
    final wait = _passWait;
    return wait != null && now.isBefore(wait);
  }

  /// A pass ran every step; what it could not finish its owners reported.
  void passRan(Listing listing) {
    _passed = true;
    _passWait = null;
    _lockFailures = 0;
    _seen = listing.records;
  }

  /// A pass could not run, or stopped part way: the next waits [base], or
  /// longer each time when a lock another app keeps was in the way.
  void passCouldNotRun(DateTime now, Duration base, {required bool locked}) {
    _passed = false;
    if (!locked) _lockFailures = 0;
    _passWait = now.add(locked ? base * (1 << min(_lockFailures++, 4)) : base);
  }

  /// A try of [id] stopped for [detail] with its record still on disk.
  void deferred(
    String journal,
    String id, {
    required Set<String> paths,
    required String detail,
    required DateTime now,
    Phase phase = Phase.pivots,
  }) {
    _owed.putIfAbsent((journal, id), () => Owed._(journal, id, since: now))
      ..paths = paths
      ..detail = detail
      ..phase = phase
      ..tried = now
      ..attempts += 1;
  }

  /// Only references are left to [id]: a plain save over its paths may go
  /// ahead.
  void savesMayPass(String journal, String id) =>
      _owed[(journal, id)]?.savesPass = true;

  /// [id] is finished, set aside or forgotten: it owes nothing.
  void settled(String journal, String id) => _owed.remove((journal, id));

  /// Remembers that [id] finished as [record]. Answers the id forgotten to
  /// make room, if one was.
  String? remember(String journal, String id, Object record) {
    final kept = _receipts.putIfAbsent(journal, LinkedHashMap.new)
      ..remove(id)
      ..[id] = record;
    if (kept.length <= receiptsKept) return null;
    final oldest = kept.keys.first;
    kept.remove(oldest);
    return oldest;
  }

  /// What [id] finished as, if this process finished it and still
  /// remembers; asking keeps it remembered longest.
  T? receipt<T extends Object>(String journal, String id) {
    final kept = _receipts[journal];
    final record = kept?.remove(id);
    if (record == null) return null;
    kept![id] = record;
    return record as T;
  }
}
