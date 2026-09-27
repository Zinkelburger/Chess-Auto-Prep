import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:dartchess/dartchess.dart' show Side;

import '../../chess/book/book_check.dart';
import '../../chess/book/played_game.dart';
import '../../workspace/books.dart';
import '../../workspace/repertoire_shelf.dart';
import 'player_analysis.dart';
import 'player_games.dart';

typedef PlayerBookGap = ({int game, LeftBook gap});

final class PlayerBook extends ChangeNotifier {
  PlayerBook(this.analysis, this.shelf, this.books) {
    analysis.addListener(_changed);
    shelf.addListener(_changed);
    books.addListener(_changed);
  }
  final PlayerAnalysis analysis;
  final RepertoireShelf shelf;
  final Books books;
  List<PlayerBookGap> gaps = const [];
  bool busy = false, _disposed = false;
  String? status;
  int _ticket = 0;
  Object? _inputs;
  Object get _key => (
    analysis.corpus,
    analysis.side,
    analysis.query,
    analysis.recentDays,
    analysis.speeds.join(','),
    shelf.version,
    books.revision,
  );
  void _changed() {
    if (_inputs == _key) return;
    _inputs = _key;
    _ticket++;
    gaps = const [];
    status = null;
    busy = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> check() async {
    if (busy || analysis.corpus == null) return;
    await books.load();
    await shelf.read(gone: () => _disposed);
    if (_disposed) return;
    final ticket = ++_ticket;
    busy = true;
    status = null;
    notifyListeners();
    try {
      if (!books.current || shelf.problem != null)
        throw StateError(
          books.problem ?? shelf.problem ?? 'The book is not ready.',
        );
      final side = analysis.side.opposite;
      final files = <BookFile>[
        for (final ref in shelf.refs)
          if (books.includes(ref))
            if (shelf.indexOf(ref) case final index? when index.side == side)
              BookFile(
                path: ref.path,
                name: ref.name,
                index: index,
                section: ref.section,
              ),
      ];
      if (files.isEmpty) {
        status = 'Choose a ${side.name} repertoire in Books, then check again.';
        return;
      }
      final corpus = analysis.corpus!;
      final indexes = analysis.gameIndexes;
      final results = await Isolate.run(() => _check(corpus, indexes, files));
      if (_disposed || ticket != _ticket) return;
      gaps = results;
      status =
          '${indexes.length} games against your ${side.name} book · ${gaps.length} reach a gap';
    } on Object catch (e) {
      if (!_disposed && ticket == _ticket) status = '$e';
    } finally {
      if (!_disposed && ticket == _ticket) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ticket++;
    analysis.removeListener(_changed);
    shelf.removeListener(_changed);
    books.removeListener(_changed);
    super.dispose();
  }
}

List<PlayerBookGap> _check(
  PlayerCorpus corpus,
  List<int> indexes,
  List<BookFile> files,
) {
  final gaps = <PlayerBookGap>[];
  for (final index in indexes) {
    final game = corpus.games[index];
    final opponent = game.tag(game.side == Side.white ? 'Black' : 'White');
    final played = readPlayedGame(
      game.source.text,
      index: index,
      username: opponent,
    );
    if (played == null) continue;
    final result = checkGame(played, files);
    if (result is LeftBook && result.kind != Deviation.mine)
      gaps.add((game: index, gap: result));
  }
  return gaps;
}
