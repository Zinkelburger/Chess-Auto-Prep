import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../chess/explorer_answer.dart';
import '../chess/fen.dart';
import '../chess/opening_index.dart';
import '../chess/pgn/chapter_line.dart';
import '../chess/tactics/game_ids.dart';
import '../diagnostics/log.dart';
import '../storage/chapter_files.dart';
import '../storage/game_store.dart';
import '../storage/my_accounts.dart';
import '../storage/my_games_files.dart';
import 'document_session.dart';
import 'file_filter.dart';
import 'index_build.dart';

/// The explorer's two sources on this machine — the open file's games and
/// the user's own — each an [OpeningIndex] built when the explorer first
/// shows it and answered from at once after that.

sealed class TreeState {
  const TreeState();
}

/// Nothing is built for the games there are now; the next [LocalGames.want]
/// builds it.
final class TreeUnbuilt extends TreeState {
  const TreeUnbuilt();
}

/// The games are being read. [total] is 0 until it is known.
final class TreeReading extends TreeState {
  const TreeReading(this.done, this.total);

  final int done;
  final int total;
}

/// Built; [notice] names a part that could not be read.
final class TreeBuilt extends TreeState {
  const TreeBuilt({this.notice});

  final String? notice;
}

/// There are no games to build from; [sentence] says so.
final class TreeEmpty extends TreeState {
  const TreeEmpty(this.sentence);

  final String sentence;
}

final class TreeFailed extends TreeState {
  const TreeFailed(this.sentence);

  final String sentence;
}

/// A set of games on this machine as an opening explorer.
abstract interface class LocalGames implements Listenable {
  TreeState get state;

  /// Builds the tree when nothing is built or being built for the games
  /// there are now. Cheap to call on every look.
  void want();

  /// What the games say about [fen], or null while there is no tree. A
  /// tree being built again for an edit of the same games still answers.
  ExplorerAnswer? answerAt(Fen fen);

  /// How many games the answers are over — `40 games`, `12 of 40 games` —
  /// or null before there is a tree.
  String? get summary;

  /// Reads the games again at the next [want]: the user's `Try again`.
  void forget();

  /// The PGN of the game the games list names [id], while it is in the
  /// tree; null otherwise.
  String? gamePgn(String id);
}

/// `This file`: the games of the document open in the workspace, narrowed
/// by the viewer's filter — the old PGN Viewer's `Tree` tab.
///
/// Follows the document. Another file, a paste onto the board or the file
/// closed stops a build still running and drops the tree at once: its
/// answers are another file's. An edit of the same file builds again and
/// keeps answering from the tree it had until the new one is there, so a
/// comment typed into a large file does not blank the table. The filter
/// narrows the answers without building anything again.
final class FileTree extends ChangeNotifier implements LocalGames {
  FileTree({required DocumentSession session, required FileFilter filter})
    : _session = session,
      _filter = filter {
    _session.addListener(_followTheDocument);
    _filter.addListener(_followTheFilter);
    _followTheDocument();
  }

  final DocumentSession _session;
  final FileFilter _filter;

  TreeState _state = const TreeUnbuilt();
  OpeningIndex? _index;
  IndexBuild? _build;
  ChapterRef? _file;
  List<ChapterLine> _lines = const [];
  GameFilter _filterSeen = GameFilter.none;
  bool _disposed = false;

  @override
  TreeState get state => _state;

  @override
  String? get summary {
    if (_index == null) return null;
    final total = _filter.total;
    return _filter.narrowing
        ? '${_filter.kept} of $total games'
        : (total == 1 ? '1 game' : '$total games');
  }

  @override
  ExplorerAnswer? answerAt(Fen fen) =>
      _index?.answer(fen, keeps: _filter.narrowing ? _filter.keeps : null);

  @override
  void want() {
    if (_state is! TreeUnbuilt || _session.chapter == null) return;
    unawaited(_run());
  }

  @override
  String? gamePgn(String id) {
    final index = int.tryParse(id);
    if (index == null || index < 0 || index >= _lines.length) return null;
    return _lines[index].text;
  }

  @override
  void forget() {
    _stop();
    _index = null;
    _state = const TreeUnbuilt();
    notifyListeners();
  }

  Future<void> _run() async {
    final lines = _lines;
    late final IndexBuild build;
    build = _build = IndexBuild.start([
      for (final line in lines) line.text,
    ], onProgress: (done) => _progress(build, done, lines.length));
    _state = TreeReading(0, lines.length);
    notifyListeners();
    final OpeningIndex? index;
    try {
      index = await build.result;
    } on Object catch (error) {
      if (_disposed || build != _build) return;
      log.w('index the games of ${_file?.path ?? 'the board'}', error);
      _build = null;
      _state = const TreeFailed('Could not read the games of this file.');
      notifyListeners();
      return;
    }
    // Cancelled, or overtaken by another file or another edit.
    if (_disposed || index == null || build != _build) return;
    _build = null;
    _index = index;
    _state = index.gameCount == index.unread
        ? const TreeEmpty('This file has no games with moves.')
        : const TreeBuilt();
    notifyListeners();
  }

  void _progress(IndexBuild build, int done, int total) {
    if (_disposed || build != _build) return;
    _state = TreeReading(done, total);
    notifyListeners();
  }

  /// Switching games reads no new lines and changes nothing here.
  void _followTheDocument() {
    final lines = _session.chapter?.lines ?? const <ChapterLine>[];
    final file = _session.source;
    if (sameLines(lines, _lines) && file == _file) return;
    final edited = file != null && file == _file;
    _lines = lines;
    _file = file;
    _stop();
    if (!edited) _index = null;
    _state = const TreeUnbuilt();
    notifyListeners();
  }

  void _followTheFilter() {
    if (_filter.applied == _filterSeen) return;
    _filterSeen = _filter.applied;
    notifyListeners();
  }

  void _stop() {
    _build?.cancel();
    _build = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    _session.removeListener(_followTheDocument);
    _filter.removeListener(_followTheFilter);
    super.dispose();
  }
}

/// `My games`: every game of the user's that is on this machine, as one
/// tree. The files the downloads keep, `games_library/<site>_<user>.pgn`
/// (what My games and Tactics read, and what the old app treats as the
/// truth), and in the old app's games database the same accounts' library
/// and Player analysis collections and its tactics archive. A game in more
/// than one of them counts once. Newest first, so the games list under the
/// table starts with the latest.
///
/// Read when the explorer first shows it, and again after [forget] — a
/// download or a changed username. A database that cannot be read leaves
/// the downloaded games in the tree and says so beside them.
final class MyGamesTree extends ChangeNotifier implements LocalGames {
  MyGamesTree({
    required AccountStore accounts,
    required GamesCache cache,
    required GameStore store,
  }) : _accounts = accounts,
       _cache = cache,
       _store = store;

  final AccountStore _accounts;
  final GamesCache _cache;
  final GameStore _store;

  TreeState _state = const TreeUnbuilt();
  OpeningIndex? _index;
  IndexBuild? _build;
  Map<String, String> _texts = const {};
  List<String> _from = const [];
  int _reads = 0;
  bool _disposed = false;

  @override
  TreeState get state => _state;

  @override
  String? get summary {
    final index = _index;
    if (index == null) return null;
    final games = index.gameCount == 1 ? '1 game' : '${index.gameCount} games';
    return _from.isEmpty ? games : '$games · ${_from.join(', ')}';
  }

  @override
  ExplorerAnswer? answerAt(Fen fen) => _index?.answer(fen);

  @override
  String? gamePgn(String id) => _texts[id];

  @override
  void want() {
    if (_state is! TreeUnbuilt) return;
    unawaited(_read());
  }

  /// The games changed: a download landed or a username changed. The
  /// tree answers as it was until the new one is built.
  @override
  void forget() {
    _reads++;
    _stop();
    _state = const TreeUnbuilt();
    notifyListeners();
  }

  Future<void> _read() async {
    final ticket = ++_reads;
    _state = const TreeReading(0, 0);
    notifyListeners();
    final MyGamesCorpus corpus;
    try {
      corpus = await _gather();
    } on Object catch (error) {
      if (_disposed || ticket != _reads) return;
      log.w('gather your games', error);
      _state = const TreeFailed('Could not read your games.');
      notifyListeners();
      return;
    }
    if (_disposed || ticket != _reads) return;
    if (corpus.texts.isEmpty) {
      _index = null;
      _texts = const {};
      _state = corpus.notice == null
          ? const TreeEmpty(
              'No games of yours are saved yet. Get games in Tactics or '
              'My games.',
            )
          : const TreeFailed('Your games database could not be read.');
      notifyListeners();
      return;
    }
    await _indexCorpus(corpus, ticket);
  }

  Future<void> _indexCorpus(MyGamesCorpus corpus, int ticket) async {
    final total = corpus.texts.length;
    late final IndexBuild build;
    build = _build = IndexBuild.start(
      corpus.texts,
      ids: corpus.ids,
      onProgress: (done) {
        if (_disposed || build != _build) return;
        _state = TreeReading(done, total);
        notifyListeners();
      },
    );
    _state = TreeReading(0, total);
    notifyListeners();
    final OpeningIndex? index;
    try {
      index = await build.result;
    } on Object catch (error) {
      if (_disposed || ticket != _reads) return;
      log.w('index your games', error);
      _state = const TreeFailed('Could not read your games.');
      notifyListeners();
      return;
    }
    if (_disposed || ticket != _reads || index == null) return;
    _build = null;
    _index = index;
    _texts = {for (final (i, id) in corpus.ids.indexed) id: corpus.texts[i]};
    _from = corpus.from;
    _state = TreeBuilt(notice: corpus.notice);
    notifyListeners();
  }

  /// Every saved game of the accounts, and the database's.
  Future<MyGamesCorpus> _gather() async {
    final accounts = await _accounts.read();
    final files = <(GameSite, List<String>)>[];
    for (final MapEntry(key: site, value: account) in accounts.entries) {
      final games = await _cache.all(site, account.username);
      if (games != null) files.add((site, games));
    }
    final collections = {
      GameCollections.tactics,
      for (final MapEntry(key: site, value: account) in accounts.entries) ...[
        GameCollections.library(site, account.username),
        ...GameCollections.analysis(site, account.username),
      ],
    };
    final stored = await _store.read(collections);
    String? notice;
    var rows = const <StoredGame>[];
    switch (stored) {
      case StoredGamesFound(:final games, :final skipped):
        rows = games;
        if (skipped > 0) log.w('read app_games.db', '$skipped rows had no PGN');
      case StoredGamesAbsent():
        break;
      case StoredGamesUnreadable(:final detail):
        log.w('read app_games.db', detail);
        notice =
            'Your games database could not be read, so only your '
            'downloaded games are here.';
    }
    return myGamesCorpus(files: files, stored: rows, notice: notice);
  }

  void _stop() {
    _build?.cancel();
    _build = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    super.dispose();
  }
}

/// The user's games gathered from everywhere they are kept, each once,
/// newest first, with the id the games list names each by.
typedef MyGamesCorpus = ({
  List<String> texts,
  List<String> ids,
  List<String> from,
  String? notice,
});

/// Merges the downloaded [files] with the database's [stored] games.
///
/// A game is the same game wherever it is kept when it names the same
/// site game (`lichess_AbCd1234`); one that names none is the same when its
/// text is. The file's copy wins, as the file is the truth the database
/// mirrors. [MyGamesCorpus.from] names where games came from, in the order
/// first met.
MyGamesCorpus myGamesCorpus({
  required List<(GameSite, List<String>)> files,
  required List<StoredGame> stored,
  String? notice,
}) {
  final byId = <String, ({String text, String played, int met})>{};
  final from = <String>[];
  void add(String text, String where) {
    final id = _idOf(text);
    if (byId.containsKey(id)) return;
    byId[id] = (text: text, played: playedAt(text), met: byId.length);
    if (!from.contains(where)) from.add(where);
  }

  for (final (site, games) in files) {
    for (final game in games) {
      add(game, site.label);
    }
  }
  for (final game in stored) {
    add(game.pgn, _collectionLabel(game.collection));
  }
  // Games that do not say when they were played keep the order they were
  // met in.
  final newest = byId.entries.toList()
    ..sort((a, b) {
      final byTime = b.value.played.compareTo(a.value.played);
      return byTime != 0 ? byTime : a.value.met.compareTo(b.value.met);
    });
  return (
    texts: [for (final entry in newest) entry.value.text],
    ids: [for (final entry in newest) entry.key],
    from: from,
    notice: notice,
  );
}

/// The site's id for the game, else a digest of its text.
String _idOf(String text) {
  final site = gameIdIn(text);
  if (site.isNotEmpty) return site;
  final digest = sha256.convert(utf8.encode(text.trim()));
  return 'pgn_${digest.toString().substring(0, 16)}';
}

String _collectionLabel(String collection) {
  if (collection == GameCollections.tactics) return 'tactics archive';
  if (collection.startsWith('analysis:')) return 'player analysis';
  for (final site in GameSite.values) {
    if (collection.startsWith('library:${site.name}_')) return site.label;
  }
  return collection;
}
