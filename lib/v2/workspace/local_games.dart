import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../chess/explorer_answer.dart';
import '../chess/fen.dart';
import '../chess/game_filter.dart';
import '../chess/opening_index.dart';
import '../chess/pgn/chapter_line.dart';
import '../chess/tactics/game_ids.dart';
import '../diagnostics/log.dart';
import '../storage/chapter_files.dart';
import '../storage/game_store.dart';
import '../storage/my_accounts.dart';
import '../storage/my_games_files.dart';
import 'file_filter.dart';
import 'index_build.dart';

/// The explorer's two sources on this machine — the open file's games and
/// the user's own — each an [OpeningIndex] built the first time the
/// explorer asks with it chosen, and answered from at once after that.

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
}

/// A tree whose listed games are not open anywhere, so opening one needs
/// its text: `My games`.
abstract interface class SavedGames implements LocalGames {
  /// The PGN of the game the games list names [id], while it is in the
  /// tree; null otherwise.
  String? gamePgn(String id);
}

/// `This file`: the games of the document open in the workspace, narrowed
/// by the viewer's filter — the old PGN Viewer's `Tree` tab. It follows
/// the document through the [FileFilter], which reads it first, so the
/// games the filter numbers are the games the tree numbers.
///
/// Another file, a paste onto the board or the file closed stops a build
/// still running and drops the tree at once: its answers are another
/// file's. An edit of the same file that keeps its number of games — a
/// comment, a move — builds again and answers from the tree it had until
/// the new one is there, so a note typed into a large file does not blank
/// the table; any other change drops it, since its game numbers would name
/// other games. The filter narrows the answers without building again.
final class FileTree extends ChangeNotifier implements LocalGames {
  FileTree({required FileFilter filter}) : _filter = filter {
    _filter.addListener(_follow);
    _follow();
  }

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
    if (_state is! TreeUnbuilt) return;
    unawaited(_run());
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

  /// The filter saw another document, or new rules. Switching games reads
  /// no new lines and changes nothing here.
  void _follow() {
    final lines = _filter.lines;
    final file = _filter.file;
    if (sameLines(lines, _lines) && file == _file) {
      if (_filter.applied == _filterSeen) return;
      _filterSeen = _filter.applied;
      notifyListeners();
      return;
    }
    final numberedAlike =
        sameFile(file, _file) && lines.length == _lines.length;
    _lines = lines;
    _file = file;
    _filterSeen = _filter.applied;
    _stop();
    if (!numberedAlike) _index = null;
    _state = const TreeUnbuilt();
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
    _filter.removeListener(_follow);
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
/// Read the first time the explorer asks, and again after [forget] — a
/// download or a changed username. A database that cannot be read leaves
/// the downloaded games in the tree and says so beside them.
final class MyGamesTree extends ChangeNotifier implements SavedGames {
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
    bool gone() => _disposed || ticket != _reads;
    final MyGamesCorpus? corpus;
    try {
      corpus = await _gather(gone);
    } on Object catch (error) {
      if (gone()) return;
      log.w('gather your games', error);
      _state = const TreeFailed('Could not read your games.');
      notifyListeners();
      return;
    }
    if (corpus == null || gone()) return;
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

  /// Every saved game of the accounts, and the database's; null once
  /// [gone] says the read was overtaken or the tree disposed.
  Future<MyGamesCorpus?> _gather(bool Function() gone) async {
    final accounts = await _accounts.read();
    if (gone()) return null;
    final files = <(GameSite, List<String>)>[];
    for (final MapEntry(key: site, value: account) in accounts.entries) {
      final games = await _cache.all(site, account.username);
      if (gone()) return null;
      if (games != null) files.add((site, games));
    }
    final stored = await _readStore({
      GameCollections.tactics,
      for (final MapEntry(key: site, value: account) in accounts.entries) ...[
        GameCollections.library(site, account.username),
        ...GameCollections.analysis(site, account.username),
      ],
    });
    if (gone()) return null;
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

  /// The database's answer; one that throws is one that could not be
  /// read, which leaves the downloaded games standing.
  Future<StoredGamesRead> _readStore(Set<String> collections) async {
    try {
      return await _store.read(collections);
    } on Object catch (error) {
      return StoredGamesUnreadable('$error');
    }
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
