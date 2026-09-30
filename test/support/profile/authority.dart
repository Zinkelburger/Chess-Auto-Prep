// The Authority table of docs/ARCHITECTURE_RENEWAL.md as code: which bytes
// under a profile are the system of record and which may be discarded. The
// contracts project a profile onto its authoritative paths, so a store that
// writes somewhere new has to say here what that path is. An unclassified
// path throws rather than being guessed.
import 'package:chess_auto_prep/storage/training_rows.dart'
    show attemptsFile, historyFile, reviewsFile, streaksFile;
import 'package:path/path.dart' as p;

enum Authority {
  /// The system of record: kept, and quarantined whole if unreadable.
  authoritative,

  /// Versions the store kept of replaced bytes (`backups/`).
  kept,

  /// What a recovery or a delete set aside: quarantine, deleted chapters,
  /// replaced training records. Never deleted by the app.
  recovery,

  /// A record naming an operation that is not finished yet.
  journal,

  /// A staged copy the next write in its folder removes or overwrites.
  staging,

  /// Rebuilt, refetched or recomputed; a failed write of it may be dropped.
  derived,

  /// The app's own log.
  log,
}

/// What [relative] (to the profile root, `/` between the parts) is. A
/// folder that only holds other entries takes the class of the area it
/// opens; a folder under Documents is the user's own, so authoritative.
/// Throws [ArgumentError] for a path no row names.
Authority classify(String relative, {bool directory = false}) {
  // The folder holding Documents and Support: stores look at it and flush
  // it, but it holds nothing of its own.
  if (relative == '.') return Authority.authoritative;
  final parts = p.posix.split(relative);
  final name = parts.last;
  final area = parts.first;
  if (area != 'Documents' && area != 'Support') {
    throw ArgumentError.value(relative, 'relative', 'outside the profile');
  }
  if (_staged(parts)) return Authority.staging;
  // The bytes ReplaceFileW could not finish replacing, kept beside them;
  // a trace spells the stamps as `<pid>` and `<time>`.
  if (RegExp(r'\.previous-(\d+|<pid>)-(\d+|<time>)$').hasMatch(name)) {
    return Authority.recovery;
  }
  if (parts.length == 1) return Authority.authoritative;
  final within = parts.sublist(1);
  final found = area == 'Support'
      ? _support(within, name)
      : _documents(within, name, directory: directory);
  return found ?? (throw ArgumentError.value(relative, 'relative', _unnamed));
}

/// What [relative] is when nothing says whether it is a folder, as in a
/// trace: a Documents path no file rule names is taken for one of the
/// user's folders. Anything else unnamed still throws.
Authority classifyAny(String relative) {
  try {
    return classify(relative);
  } on ArgumentError {
    return classify(relative, directory: true);
  }
}

/// Whether SQLite, not the traced stores, writes [relative]: its atomicity
/// is SQLite's, so it is left out of traces and projections.
bool sqliteManaged(String relative) =>
    p.posix.split(relative).first == 'Support' &&
    RegExp(r'\.db(-wal|-shm|-journal)?$').hasMatch(relative);

/// Whether [relative] is under `Support/recovery-quarantine/`, where a
/// record or file goes that recovery could not finish.
bool quarantined(String relative) =>
    relative.startsWith('Support/recovery-quarantine/');

const _unnamed =
    'no row of the Authority table names it; add it to authority.dart';

const _trainingFiles = {reviewsFile, streaksFile, historyFile, attemptsFile};

const _journalFolders = {
  'compound-writes',
  'relocation-writes',
  'training-writes',
  'backup-moves',
  'unfinished-moves',
  'repertoire-mutations',
};

/// A staged copy (`.<name>.v2-tmp`) or anything in an import's staging
/// folder (`.import-<id>`).
bool _staged(List<String> parts) =>
    RegExp(r'^\..*\.v2-tmp').hasMatch(parts.last) ||
    parts.any((part) => part.startsWith('.import-'));

Authority? _support(List<String> parts, String name) {
  final top = parts.first;
  if (parts.length == 1 && {'books.json', 'settings.json'}.contains(name)) {
    return Authority.authoritative;
  }
  if (top == 'logs') return Authority.log;
  if (top == 'backups') return Authority.kept;
  if (top == 'recovery-quarantine') return Authority.recovery;
  if (_journalFolders.contains(top)) return Authority.journal;
  if (parts.length == 1 && sqliteManaged('Support/$name')) {
    // The user's games; every other database is an index or a cache.
    return name.startsWith('app_games.db')
        ? Authority.authoritative
        : Authority.derived;
  }
  if (top == 'bughouse' || top == 'player-reports') return Authority.derived;
  return null;
}

Authority? _documents(
  List<String> parts,
  String name, {
  required bool directory,
}) {
  if (parts.first == '.cap-reference-history') return Authority.recovery;
  if (parts.contains('.cap-pgn-history')) return Authority.recovery;
  if (parts.contains('.cap-repertoire-publications')) return Authority.journal;
  if (parts.contains('.cap-generation')) return Authority.derived;
  if (parts.first == 'games_library') return Authority.derived;
  if (name == 'games.bpgn') return Authority.derived;
  if (name == '.v2-pending.json') return Authority.journal;
  if (parts.length == 1) {
    if (_trainingFiles.contains(name)) return Authority.authoritative;
    if (name.endsWith('.pre-csv-v2.bak')) return Authority.kept;
    if (name == 'analyzed_games.txt') return Authority.authoritative;
  }
  if (p.posix.extension(name).toLowerCase() == '.pgn') {
    return Authority.authoritative;
  }
  if ({'tournament.json', 'people.json', 'match.json'}.contains(name)) {
    return Authority.authoritative;
  }
  return directory ? Authority.authoritative : null;
}
