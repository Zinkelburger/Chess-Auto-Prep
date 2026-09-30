import 'dart:async';
import 'dart:isolate';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';

import '../chess/fen.dart';
import '../chess/generation/finds.dart';
import '../chess/generation/search_node.dart';
import '../diagnostics/log.dart';
import '../storage/finds_store.dart';
import '../storage/pending_writes.dart';

/// How the Positions list is ordered.
enum FindOrder {
  /// How often it comes up times how much it matters.
  worth,

  /// How often a game from where the search started gets there.
  reach,

  /// The last found first.
  newest,
}

/// What the last search added to the finds.
sealed class FindsRecorded {
  const FindsRecorded();
}

final class FindsReading extends FindsRecorded {
  const FindsReading();
}

final class FindsUnsaved extends FindsRecorded {
  const FindsUnsaved(this.reason);
  final String reason;
}

final class FindsKept extends FindsRecorded {
  const FindsKept(this.count);

  final int count;
}

/// The positions every search has pointed out, kept between runs, and the
/// Positions list's view of them: its order, the kinds it shows and the
/// find on the board.
///
/// A search hands its tree here when it stops ([record]); what the tree
/// holds is worked out off the window's isolate when it is big, then kept
/// in the store. The store is read the first time the list is shown.
final class Finds extends ChangeNotifier {
  Finds({
    required FindsStore Function() store,
    DateTime Function()? clock,
    PendingWrites? pendingWrites,
  }) : _store = store,
       _pending = pendingWrites ?? PendingWrites(),
       _clock = clock ?? DateTime.now;

  /// Opens the store; asked once, when it is first needed.
  final FindsStore Function() _store;
  FindsStore? _opened;
  FindsStore get _db =>
      (_opened?.available ?? false) ? _opened! : _opened = _store();
  final PendingWrites _pending;
  PendingObligation<FindsRecorded>? _latest;
  bool get canRetry => _pending.unfinished(_store).isNotEmpty;
  final DateTime Function() _clock;

  List<KeptFind>? _all;
  List<KeptFind>? _shown;
  FindOrder _order = FindOrder.worth;
  FindKind? _kind;
  int? _selected;
  FindsRecorded? _recorded;
  bool _disposed = false;

  /// Every find kept; empty until [load].
  List<KeptFind> get all => _all ?? const [];

  bool get loaded => _all != null;

  FindOrder get order => _order;

  /// The one kind shown; null shows every kind.
  FindKind? get kind => _kind;

  /// The find last opened, whose row is marked.
  int? get selected => _selected;

  /// What the last search added, once one has stopped.
  FindsRecorded? get recorded =>
      _recorded ??
      (canRetry
          ? const FindsUnsaved('Search positions have not been saved.')
          : null);

  /// The finds of the kinds shown, in the order chosen.
  List<KeptFind> get shown => _shown ??= _sorted([
    for (final kept in all)
      if (_kind == null || kept.find.kind == _kind) kept,
  ]);

  /// Reads the store once; later calls do nothing.
  void load() {
    if (_all != null) return;
    _all = _db.all();
    _changed();
  }

  void sortBy(FindOrder order) {
    if (order == _order) return;
    _order = order;
    _changed();
  }

  /// Shows only [kind], or every kind when null.
  void show(FindKind? kind) {
    if (kind == _kind) return;
    _kind = kind;
    _changed();
  }

  void select(int id) {
    if (_selected == id) return;
    _selected = id;
    notifyListeners();
  }

  /// The find [by] rows from the one on the board in the list as shown:
  /// the first when none is; null past either end.
  KeptFind? step(int by) {
    final list = shown;
    if (list.isEmpty) return null;
    final at = list.indexWhere((kept) => kept.id == _selected);
    final next = at < 0 ? (by > 0 ? 0 : list.length - 1) : at + by;
    return next < 0 || next >= list.length ? null : list[next];
  }

  void remove(int id) {
    _db.remove(id);
    _all = [
      for (final kept in all)
        if (kept.id != id) kept,
    ];
    if (_selected == id) _selected = null;
    _changed();
  }

  /// Works out the finds of a stopped search's [tree] and keeps them. The
  /// tree starts where the board stood, [prefix] from [rootFen].
  Future<FindsRecorded> record(
    SearchNode tree, {
    required Fen rootFen,
    required List<String> prefix,
    required Side side,
    required int elo,
  }) {
    if (_disposed)
      return Future.value(const FindsUnsaved('The search owner is closed.'));
    final acceptedAt = _clock();
    final acceptedPrefix = List<String>.unmodifiable(prefix);
    List<Find>? lines;
    final entry = _pending.accept<FindsRecorded>(
      resource: _store,
      label: 'Search positions',
      work: () async {
        try {
          lines ??= [
            for (final find in await _findsIn(tree)) find.after(acceptedPrefix),
          ];
          final kept = _db.keep(
            lines!,
            side: side,
            rootFen: rootFen,
            elo: elo,
            at: acceptedAt,
          );
          return kept
              ? FindsKept(lines!.length)
              : const FindsUnsaved(
                  'Search positions could not be saved. Retry saving them.',
                );
        } on Object catch (error) {
          log.w('keep search positions', error);
          return const FindsUnsaved(
            'Search positions could not be saved. Retry saving them.',
          );
        }
      },
      problem: (result) => result is FindsUnsaved ? result.reason : null,
      blocked: () =>
          const FindsUnsaved('An earlier search still needs saving.'),
    );
    _latest = entry;
    _recorded = const FindsReading();
    notifyListeners();
    return _record(entry);
  }

  Future<FindsRecorded> _record(PendingObligation<FindsRecorded> entry) async {
    final result = await entry.run();
    if (!_disposed && identical(_latest, entry)) _adopt(result);
    return result;
  }

  /// Retry accepted batches in order; their frozen timestamps and payloads
  /// belong to the app registry even after this list is replaced.
  Future<bool> retry() async {
    final entries = _pending.unfinished(_store);
    await _pending.retry(_store);
    if (_disposed) return !canRetry;
    if (entries.isNotEmpty) {
      final result = entries.last.result;
      if (result is FindsRecorded) _adopt(result);
    }
    return !canRetry;
  }

  void _adopt(FindsRecorded result) {
    _recorded = result;
    if (result is FindsKept && _all != null) _all = _db.all();
    _changed();
  }

  List<KeptFind> _sorted(List<KeptFind> list) {
    int by(KeptFind a, KeptFind b) => switch (_order) {
      FindOrder.worth => b.find.worth.compareTo(a.find.worth),
      FindOrder.reach => b.find.reach.compareTo(a.find.reach),
      FindOrder.newest => b.foundAt.compareTo(a.foundAt),
    };
    return list..sort((a, b) {
      final order = by(a, b);
      return order != 0 ? order : a.id.compareTo(b.id);
    });
  }

  void _changed() {
    _shown = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A tree with more nodes than this is read for finds on another isolate.
const _offThreadFrom = 2000;

Future<List<Find>> _findsIn(SearchNode tree) {
  List<Find> work() => findsOf(tree);
  return _count(tree, _offThreadFrom) < _offThreadFrom
      ? Future.value(work())
      : Isolate.run(work);
}

/// The nodes of [node], counted no further than [upTo].
int _count(SearchNode node, int upTo) {
  var n = 0;
  final stack = [node];
  while (stack.isNotEmpty && n < upTo) {
    n++;
    switch (stack.removeLast()) {
      case OurNode(:final candidates):
        stack.addAll(candidates.map((c) => c.child));
      case OpponentNode(:final replies):
        stack.addAll(replies.map((r) => r.child));
      default:
    }
  }
  return n;
}
