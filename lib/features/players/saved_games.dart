import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../chess/pgn/chapter.dart' show readOffThreadFrom;
import '../../chess/pgn/game_text.dart';
import '../../chess/players/player.dart';
import '../../chess/tactics/game_ids.dart';
import '../../diagnostics/log.dart';
import '../../storage/document_ref.dart';
import '../../storage/my_accounts.dart';
import '../../storage/my_games_files.dart';
import '../../storage/pgn_document_store.dart';
import '../../storage/player_reports.dart';
import 'players.dart';

/// A person's account whose downloaded games stay when their games are
/// deleted, because another reader shares the file: the user's own account
/// ([otherPerson] null), which My games, Tactics and the book check read,
/// or an account [otherPerson] holds too.
typedef KeptDownload = ({GameSite site, String username, String? otherPerson});

/// What is saved for one person: games downloaded for their accounts, the
/// ones of those a delete would leave ([kept], [keptGames]), games in the
/// PGN files linked to them, and when the stalest download came.
/// [keptKnown] is false when the user's own accounts could not be read:
/// what a delete would leave is then unknown, and nothing can be deleted.
typedef GamesSummary = ({
  int downloaded,
  int linked,
  DateTime? fetched,
  List<KeptDownload> kept,
  int keptGames,
  bool keptKnown,
});

extension GamesSummaryDeletable on GamesSummary {
  /// How many downloaded games a delete would move to recovery: none while
  /// what it would keep is unknown.
  int get deletable => keptKnown ? downloaded - keptGames : 0;
}

/// The directory's view of each person's saved games, and the command that
/// deletes their downloads.
///
/// The counts are derived: recounted when a person's name, accounts or
/// linked files change ([refresh] recounts on demand, [current] when the
/// user's own accounts changed since), and a count begun for an older list
/// is dropped. A file is counted again only when its
/// bytes changed since it was last counted. A file that cannot be read
/// counts as none; it never blocks the directory.
final class SavedGames extends ChangeNotifier {
  SavedGames(
    this.players,
    this.cache,
    this.documents,
    this.reports,
    this.mine,
  ) {
    players.addListener(_peopleChanged);
  }

  final Players players;
  final GamesCache cache;
  final PgnDocumentStore documents;
  final PlayerReports reports;

  /// The user's own accounts, whose downloads are never deleted here.
  final AccountStore mine;

  Map<String, GamesSummary> _summaries = const {};
  String? _inputs;

  /// The revision of the user's accounts [_summaries] were counted against,
  /// or null when they could not be read.
  int? _countedWith;
  final _counts = <String, ({Revision revision, int games})>{};
  int _ticket = 0;
  bool _disposed = false;

  /// The ids of people whose downloads are being deleted.
  final Set<String> deleting = {};

  GamesSummary? of(Player person) => _summaries[person.id];

  /// [person]'s summary counted against the user's accounts as they are
  /// now: recounted first when those changed since the last count, or
  /// could not be read then. What a delete is confirmed with.
  Future<GamesSummary?> current(Player person) async {
    if (_countedWith == null || _countedWith != mine.revision) await refresh();
    return of(person);
  }

  void _peopleChanged() {
    final inputs = _inputsOf(players.players);
    if (inputs == _inputs) return;
    _inputs = inputs;
    unawaited(refresh());
  }

  /// What the counts depend on: who each person is, their accounts' files
  /// and their linked files. A dismissed finding changes none of these.
  String _inputsOf(List<Player> people) => jsonEncode([
    for (final person in people)
      [
        person.id,
        person.name,
        for (final account in person.accounts)
          cache.refFor(account.site, account.username).path,
        '|',
        ...person.files,
      ],
  ]);

  Future<void> refresh() async {
    final ticket = ++_ticket;
    final people = players.players;
    final revision = mine.revision;
    final shared = await _sharedDownloads(people);
    if (_disposed || ticket != _ticket) return;
    final next = <String, GamesSummary>{};
    for (final person in people) {
      final summary = await _summary(person, shared);
      if (_disposed || ticket != _ticket) return;
      next[person.id] = summary;
    }
    _summaries = next;
    _countedWith = shared == null ? null : revision;
    notifyListeners();
  }

  Future<GamesSummary> _summary(Player person, _Shared? shared) async {
    var downloaded = 0, linked = 0, keptGames = 0;
    DateTime? fetched;
    final kept = <KeptDownload>[];
    for (final account in _accountsOf(person)) {
      final ref = cache.refFor(account.site, account.username);
      final games = await _count(ref);
      downloaded += games;
      if (shared?.keeps(person, ref.path, account) case final why?) {
        kept.add(why);
        keptGames += games;
      }
      final at = await cache.fetchedAt(account.site, account.username);
      if (at != null && (fetched == null || at.isBefore(fetched))) fetched = at;
    }
    for (final path in person.files) {
      linked += await _count(DocumentRef(path));
    }
    return (
      downloaded: downloaded,
      linked: linked,
      fetched: fetched,
      kept: kept,
      keptGames: keptGames,
      keptKnown: shared != null,
    );
  }

  /// How many games [ref] holds, parsed again only when its bytes changed.
  Future<int> _count(DocumentRef ref) async {
    final read = await documents.open(ref);
    if (read is! Opened) return 0;
    final known = _counts[ref.path];
    if (known != null && known.revision == read.revision) return known.games;
    final games = await _gamesIn(read.text);
    _counts[ref.path] = (revision: read.revision, games: games);
    return games;
  }

  /// Who else reads each downloads file: the user through their own
  /// accounts, or another person. Null when the user's accounts cannot be
  /// read, when nothing can be said to be safe to delete.
  Future<_Shared?> _sharedDownloads(List<Player> people) async {
    final read = await mine.snapshot();
    if (read is! AccountsSnapshot) return null;
    final holders = <String, List<Player>>{};
    for (final person in people) {
      for (final account in _accountsOf(person)) {
        final path = cache.refFor(account.site, account.username).path;
        (holders[path] ??= []).add(person);
      }
    }
    return _Shared(
      yours: {
        for (final MapEntry(key: site, value: account) in read.accounts.entries)
          cache.refFor(site, account.username).path,
      },
      holders: holders,
    );
  }

  /// Moves [person]'s downloaded games to the recovery folder and deletes
  /// their engine reports. Linked PGN files are the user's own and stay, and
  /// so does every download another reader shares ([GamesSummary.kept]),
  /// worked out again here rather than taken from the last count; when that
  /// is not what [confirmed], the summary the user agreed to, said it would
  /// keep, nothing is touched. Stops at the first account whose file could
  /// not be moved.
  Future<GamesDiscard> delete(
    Player person, {
    required GamesSummary confirmed,
  }) async {
    if (!deleting.add(person.id)) return const GamesNotDiscarded('busy');
    _notify();
    final shared = await _sharedDownloads(players.players);
    GamesDiscard result = const GamesDiscarded(null);
    if (shared == null) {
      result = const GamesNotDiscarded(
        'your own accounts could not be read, so no download was touched',
      );
    } else if (!confirmed.keptKnown ||
        !listEquals(_keptBy(shared, person), confirmed.kept)) {
      result = const GamesNotDiscarded(
        'which downloads stay changed since you confirmed, so none was '
        'touched',
      );
    } else {
      for (final account in _accountsOf(person)) {
        final ref = cache.refFor(account.site, account.username);
        if (shared.keeps(person, ref.path, account) != null) continue;
        final discarded = await cache.discard(account.site, account.username);
        if (discarded is GamesNotDiscarded) {
          log.w('delete the saved games of ${person.name}', discarded.detail);
          result = discarded;
          break;
        }
        if (discarded case GamesDiscarded(recoveredTo: _?)) result = discarded;
      }
    }
    if (result is GamesDiscarded) await reports.discardFor(person.id);
    deleting.remove(person.id);
    _notify();
    if (!_disposed) unawaited(refresh());
    return result;
  }

  /// The downloads of [person] a delete leaves, as [_summary] lists them.
  List<KeptDownload> _keptBy(_Shared shared, Player person) => [
    for (final account in _accountsOf(person))
      if (shared.keeps(
            person,
            cache.refFor(account.site, account.username).path,
            account,
          )
          case final why?)
        why,
  ];

  /// [person]'s accounts, each file once: two spellings of one username
  /// are one file.
  List<({GameSite site, String username})> _accountsOf(Player person) {
    final seen = <String>{};
    return [
      for (final account in person.accounts)
        if (seen.add(cache.refFor(account.site, account.username).path))
          account,
    ];
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    players.removeListener(_peopleChanged);
    super.dispose();
  }
}

/// Which downloads files a delete must leave, by path.
final class _Shared {
  const _Shared({required this.yours, required this.holders});

  /// The files of the user's own accounts.
  final Set<String> yours;

  /// Everyone holding each file.
  final Map<String, List<Player>> holders;

  /// Why [person]'s download of [account] at [path] stays, or null when it
  /// can go.
  KeptDownload? keeps(
    Player person,
    String path,
    ({GameSite site, String username}) account,
  ) {
    final other = holders[path]?.where((p) => p.id != person.id).firstOrNull;
    if (!yours.contains(path) && other == null) return null;
    return (
      site: account.site,
      username: account.username,
      otherPerson: yours.contains(path) ? null : other!.name,
    );
  }
}

Future<int> _gamesIn(String text) {
  int count() => splitChapterText(text).games.length;
  return text.length < readOffThreadFrom
      ? Future.value(count())
      : Isolate.run(count);
}
