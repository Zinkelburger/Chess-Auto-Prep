import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/game_text.dart';
import '../../chess/pgn/games_written.dart';
import '../../chess/tactics/game_ids.dart';
import '../../net/recent_games.dart';
import '../../storage/document_ref.dart';
import '../../storage/edit_scope.dart';
import '../../storage/game_store.dart';
import '../../storage/my_games_files.dart';
import '../../storage/pending_writes.dart';
import '../../storage/pgn_document_store.dart';
import '../../ui/relative_time.dart';
import '../../chess/players/player.dart';
import '../../chess/players/download_range.dart';
import 'player_games.dart';

enum PositionOrder { frequent, lowScore, highScore, badEval }

enum PlayerList { openings, games, weaknesses }

/// One selected corpus, built independently of the document on the board.
/// Sources retain their real game indices, so opening a filtered row cannot
/// accidentally show a different game. Selection tickets discard late work.
final class PlayerAnalysis extends ChangeNotifier {
  PlayerAnalysis({
    required this.documents,
    required this.archive,
    required this.cache,
    required this.sites,
    required this.pending,
    required this.archiveCopies,
  });
  final PgnDocumentStore documents;
  final GameStore archive;
  final GamesCache cache;
  final List<RecentGames> sites;
  final PendingWrites pending;

  /// Where a player's games from the old app's database are copied to be
  /// read and opened like any other file: one derived file per player,
  /// beside the downloads, never among the user's collections.
  final String archiveCopies;
  Player? player;
  PlayerCorpus? corpus;
  Side side = Side.white;
  PositionOrder order = PositionOrder.frequent;
  PlayerList list = PlayerList.openings;
  String query = '';
  int minGames = 1, minPly = 2;
  int? recentDays;

  /// The time controls the games are narrowed to; none is every game, and
  /// [TimeClass.unknown] is the Other choice.
  Set<TimeClass> speeds = {};
  bool busy = false;
  String? status, error;
  List<String> warnings = const [];
  int _ticket = 0;
  bool _disposed = false;
  final Map<DocumentRef, Revision> _revisions = {};
  final Map<String, int> evals = {};

  void changed() {
    if (!_disposed) notifyListeners();
  }

  void setSide(Side value) {
    side = value;
    changed();
  }

  void search(String value) {
    query = value;
    changed();
  }

  void configure({
    PlayerList? list,
    PositionOrder? order,
    int? minGames,
    int? minPly,
  }) {
    this.list = list ?? this.list;
    this.order = order ?? this.order;
    this.minGames = minGames ?? this.minGames;
    this.minPly = minPly ?? this.minPly;
    changed();
  }

  bool includes(AnalyzedGame game) {
    if (game.side != side || !game.search.contains(query.toLowerCase()))
      return false;
    if (recentDays != null) {
      final date = DateTime.tryParse(game.date.replaceAll('.', '-'));
      if (date == null ||
          date.isBefore(DateTime.now().subtract(Duration(days: recentDays!))))
        return false;
    }
    if (speeds.isNotEmpty &&
        !speeds.contains(
          timeClassOfTags({
            for (final key in const ['TimeControl', 'Site', 'Link'])
              key: game.tag(key),
          }),
        ))
      return false;
    return true;
  }

  List<int> get gameIndexes => [
    for (final (i, g) in (corpus?.games ?? <AnalyzedGame>[]).indexed)
      if (includes(g)) i,
  ];
  List<PlayerPosition> get positions {
    final data = corpus;
    if (data == null) return const [];
    // Filtering statistics is done over the actual games, not by hiding rows
    // after counts were taken from a broader corpus.
    final result = <PlayerPosition>[];
    for (final at in data.positions) {
      if (at.side != side || at.ply < minPly) continue;
      final included = at.games.where((i) => includes(data.games[i])).toList();
      if (included.length < minGames) continue;
      final filtered = PlayerPosition(
        fen: at.fen,
        side: at.side,
        line: at.line,
        game: included.first,
        ply: at.ply,
      );
      for (final index in included) {
        final game = data.games[index];
        filtered.games.add(index);
        if (game.result == '1/2-1/2') {
          filtered.draws++;
        } else if (game.result == (side == Side.white ? '1-0' : '0-1')) {
          filtered.wins++;
        } else if (game.result == (side == Side.white ? '0-1' : '1-0')) {
          filtered.losses++;
        } else {
          filtered.unknown++;
        }
      }
      if (filtered.count >= minGames) result.add(filtered);
    }
    result.sort((a, b) {
      final by = switch (order) {
        PositionOrder.frequent => b.count.compareTo(a.count),
        PositionOrder.lowScore => (a.score ?? 2).compareTo(b.score ?? 2),
        PositionOrder.highScore => (b.score ?? -1).compareTo(a.score ?? -1),
        PositionOrder.badEval => (evals[a.key] ?? 100000).compareTo(
          evals[b.key] ?? 100000,
        ),
      };
      return by != 0 ? by : a.ply.compareTo(b.ply);
    });
    return result;
  }

  void cancel() {
    _ticket++;
    busy = false;
    status = null;
    changed();
  }

  bool _current(int ticket) => !_disposed && ticket == _ticket;
  Future<void> select(Player next, {bool download = false}) async {
    final ticket = ++_ticket;
    final same = player?.id == next.id;
    player = next;
    busy = true;
    status = download ? 'Downloading games…' : 'Reading saved games…';
    error = null;
    warnings = const [];
    corpus = null;
    if (!same) query = '';
    evals.clear();
    _revisions.clear();
    changed();
    final notes = <String>[];
    try {
      if (download) await _download(next, ticket, notes);
      if (!_current(ticket)) return;
      final (games, revisions) = await _readGames(next, ticket, notes);
      if (!_current(ticket)) return;
      status = 'Building openings from ${games.length} games…';
      changed();
      final result = await analyzePlayerGames(next, games);
      final fetched = await _stalestDownload(next);
      if (!_current(ticket)) return;
      if (!await _validate(revisions, ticket))
        throw StateError('Games changed while being read. Reload this player.');
      corpus = result;
      _revisions.addAll(revisions);
      warnings = notes;
      if (!same &&
          !result.games.any((g) => g.side == side) &&
          result.games.isNotEmpty)
        side = result.games.first.side;
      status = result.games.isEmpty
          ? 'No matching games. Add an account or PGN file, and check the player’s name and aliases.'
          : [
              '${result.games.length} ${result.games.length == 1 ? 'game' : 'games'}',
              for (final a in next.accounts) '${a.site.label} (${a.username})',
              if (fetched != null) 'downloaded ${relativeTime(fetched)}',
              if (result.unmatched > 0) '${result.unmatched} unmatched',
              if (result.unread > 0)
                '${result.unread} unreadable or nonstandard',
            ].join(' · ');
    } on Object catch (e) {
      if (_current(ticket)) {
        error = '$e';
        corpus = null;
      }
    } finally {
      if (_current(ticket)) {
        busy = false;
        changed();
      }
    }
  }

  /// When the least recent of [next]'s accounts was downloaded: how stale
  /// the corpus may be.
  Future<DateTime?> _stalestDownload(Player next) async {
    DateTime? stalest;
    for (final account in next.accounts) {
      final at = await cache.fetchedAt(account.site, account.username);
      if (at != null && (stalest == null || at.isBefore(stalest))) stalest = at;
    }
    return stalest;
  }

  Future<void> _download(Player next, int ticket, List<String> notes) async {
    for (final account in next.accounts) {
      if (!_current(ticket)) return;
      status =
          'Downloading ${account.site.label} games for ${account.username}…';
      changed();
      final api = sites.where((s) => s.site == account.site).firstOrNull;
      if (api == null) continue;
      final range = PlayerDownloadRange.from(next.fields['download']);
      final fetched = api is RangedGames
          ? await api.range(
              account.username,
              range,
              cancelled: () => !_current(ticket),
              progress: (value) {
                if (_current(ticket)) {
                  status = value;
                  changed();
                }
              },
            )
          : await api.recent(account.username, max: range.max);
      if (!_current(ticket)) return;
      await _keepDownload(account.site, account.username, fetched, notes);
    }
  }

  Future<void> _keepDownload(
    GameSite site,
    String username,
    GamesFetch fetched,
    List<String> notes,
  ) async {
    switch (fetched) {
      case GamesFetched(:final games):
        final keeping = cache.keep(site, username, games, DateTime.now());
        pending.watch(this, keeping);
        final kept = await keeping;
        if (kept is GamesNotKept)
          notes.add(
            '${site.label}: could not save downloaded games. ${kept.detail}',
          );
      case GamesNotFetched(:final problem):
        notes.add(
          '${site.label}: ${switch (problem) {
            GamesProblem.noSuchPlayer => 'username not found',
            GamesProblem.rateLimited => 'download limit reached; try again later',
            _ => 'could not download; showing saved games',
          }}.',
        );
    }
  }

  Future<(List<PlayerGame>, Map<DocumentRef, Revision>)> _readGames(
    Player next,
    int ticket,
    List<String> notes,
  ) async {
    final paths = next.files.toSet();
    for (final account in next.accounts) {
      paths.add(cache.refFor(account.site, account.username).path);
    }
    final names = <String>{
      for (final account in next.accounts)
        ...GameCollections.analysis(account.site, account.username),
      for (final key in next.strings('game_sets')) 'analysis:$key',
    };
    if (names.isNotEmpty) {
      final archived = await archive.read(names);
      if (!_current(ticket)) return (<PlayerGame>[], <DocumentRef, Revision>{});
      if (archived is StoredGamesUnreadable)
        notes.add('Older saved games could not be read. ${archived.detail}');
      if (archived is StoredGamesFound && archived.games.isNotEmpty) {
        final ref = _archiveCopyOf(next);
        // The downloads and linked files are still read without it.
        final problem = await _copy(ref, [
          for (final g in archived.games) g.pgn,
        ]);
        if (problem == null) {
          paths.add(ref.path);
        } else {
          notes.add('Older saved games could not be shown. $problem');
        }
      }
    }
    final games = <PlayerGame>[];
    final revisions = <DocumentRef, Revision>{};
    for (final path in paths) {
      if (!_current(ticket)) return (<PlayerGame>[], <DocumentRef, Revision>{});
      final ref = DocumentRef(path);
      switch (await documents.open(ref)) {
        case Opened(:final text, :final revision):
          revisions[ref] = revision;
          for (final (i, g) in splitChapterText(text).games.indexed) {
            games.add(PlayerGame(file: ref, index: i, text: g.text));
          }
        case Unreadable(:final detail):
          notes.add('${p.basename(path)}: $detail');
        case Absent():
          if (next.files.contains(path))
            notes.add('${p.basename(path)} is missing. Link the file again.');
      }
    }
    return (games, revisions);
  }

  /// [player]'s one copy of their games in the old app's database. Games
  /// are only ever added to it, so what the user keeps there survives.
  DocumentRef _archiveCopyOf(Player player) {
    final id = sha256.convert(utf8.encode(player.id)).toString();
    return DocumentRef(
      p.join(archiveCopies, 'player-archive-${id.substring(0, 16)}.pgn'),
    );
  }

  /// Appends the [games] that [ref] does not have yet; why not, or null.
  /// A game is matched by its site id, or else by its exact text.
  Future<String?> _copy(DocumentRef ref, List<String> games) async {
    try {
      switch (await documents.open(ref)) {
        case Opened(readOnly: null, :final text, :final revision):
          final fresh = await freshGamesOf(text, games);
          if (fresh.isEmpty) return null;
          final base = text.trimRight();
          final joined = fresh.join('\n\n');
          return switch (await documents.save(
            ref,
            base.isEmpty ? '$joined\n' : '$base\n\n$joined\n',
            expected: revision,
            scope: GamesEdited(GamesWritten(appended: fresh.length)),
          )) {
            Saved() => null,
            Conflict() => 'the copy changed while it was written',
            SaveDidNotLand(:final detail) => detail,
          };
        case Opened(:final readOnly?):
          return readOnly;
        case Absent():
          final fresh = await freshGamesOf('', games);
          return switch (await documents.create(
            ref,
            '${fresh.join('\n\n')}\n',
          )) {
            Created() => null,
            Collision() => 'the copy appeared while it was written',
            IoFailure(:final detail) => detail,
          };
        case Unreadable(:final detail):
          return detail;
      }
    } on Object catch (error) {
      return '$error';
    }
  }

  Future<bool> _validate(
    Map<DocumentRef, Revision> revisions,
    int ticket,
  ) async {
    for (final e in revisions.entries) {
      final read = await documents.open(e.key);
      if (!_current(ticket) || read is! Opened || read.revision != e.value)
        return false;
    }
    return _current(ticket);
  }

  String get fingerprint => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            player?.id,
            player?.names,
            for (final entry in _revisions.entries)
              [entry.key.path, entry.value.contentHash],
          ]),
        ),
      )
      .toString();
  Revision? revisionOf(DocumentRef ref) => _revisions[ref];

  Future<bool> currentSources() async {
    if (busy || corpus == null) return false;
    final ticket = _ticket;
    final revisions = Map.of(_revisions);
    for (final e in revisions.entries) {
      final read = await documents.open(e.key);
      if (!_current(ticket) || read is! Opened || read.revision != e.value)
        return false;
    }
    return _current(ticket);
  }

  @override
  void dispose() {
    _disposed = true;
    _ticket++;
    super.dispose();
  }
}
