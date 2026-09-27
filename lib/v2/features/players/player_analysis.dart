import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/game_text.dart';
import '../../chess/tactics/game_ids.dart';
import '../../net/recent_games.dart';
import '../../storage/document_ref.dart';
import '../../storage/game_store.dart';
import '../../storage/my_games_files.dart';
import '../../storage/pending_writes.dart';
import '../../storage/pgn_document_store.dart';
import '../../chess/players/player.dart';
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
    required this.collections,
  });
  final PgnDocumentStore documents;
  final GameStore archive;
  final GamesCache cache;
  final List<RecentGames> sites;
  final PendingWrites pending;
  final String collections;
  Player? player;
  PlayerCorpus? corpus;
  Side side = Side.white;
  PositionOrder order = PositionOrder.frequent;
  PlayerList list = PlayerList.openings;
  String query = '';
  int minGames = 1, minPly = 2, maxGames = 500;
  int? recentDays;
  Set<String> speeds = {};
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
        !speeds.contains(gameSpeed(game.tag('TimeControl'))))
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
      final filtered = PlayerPosition(
        fen: at.fen,
        side: at.side,
        line: at.line,
        game: at.game,
        ply: at.ply,
      );
      for (final index in at.games) {
        final game = data.games[index];
        if (!includes(game)) continue;
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
              '${result.games.length} saved games',
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

  Future<void> _download(Player next, int ticket, List<String> notes) async {
    for (final account in next.accounts) {
      if (!_current(ticket)) return;
      status =
          'Downloading ${account.site.label} games for ${account.username}…';
      changed();
      final api = sites.where((s) => s.site == account.site).firstOrNull;
      if (api == null) continue;
      final fetched = await api.recent(account.username, max: maxGames);
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
        final text = archived.games.map((g) => g.pgn).join('\n\n');
        final hash = sha256.convert(utf8.encode(text));
        final ref = DocumentRef(p.join(collections, 'player-$hash.pgn'));
        final stored = await documents.open(ref);
        if (stored is Absent) {
          final result = await documents.create(ref, text);
          if (result is! Created && result is! Collision)
            throw StateError('Could not open the older saved games.');
        }
        paths.add(ref.path);
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

String gameSpeed(String control) {
  final parts = control.split('+');
  final base = int.tryParse(parts.first) ?? 0;
  if (base == 0 || control.contains('/')) return 'Other';
  final seconds =
      base + 40 * (parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0);
  return seconds < 180
      ? 'Bullet'
      : seconds < 600
      ? 'Blitz'
      : seconds < 1800
      ? 'Rapid'
      : 'Classical';
}
