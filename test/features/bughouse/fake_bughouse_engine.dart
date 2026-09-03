import 'dart:async';

import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:dartchess/dartchess.dart';

/// A scripted stand-in for Hivemind.
///
/// The controller's analysis loop — a pump that alternates teams and lengthens
/// its passes, generation invalidation, the scenario comparison — is the most
/// intricate code in the feature and used to have no coverage at all, because
/// the only injectable engine was a real 54 MB process. This records what it
/// was asked and answers whatever the test told it to.
class FakeBughouseEngine implements BughouseAnalysisEngine {
  FakeBughouseEngine({this.searchDelay = Duration.zero});

  /// How long each [search] takes to answer, so a test can hold one open and
  /// act while it is in flight.
  Duration searchDelay;

  /// One entry per [configure], in order.
  final List<
    ({
      Side team,
      bool hasTimeAdvantage,
      RequireMoveOn requireMoveOn,
      int multiPv,
    })
  >
  configurations = [];

  /// One entry per [setPosition].
  final List<String> positions = [];

  /// One entry per [search].
  final List<({Duration? movetime, int? nodes})> searches = [];

  int stops = 0;
  int disposals = 0;

  @override
  String get backend => 'fake';

  @override
  String get backendDetail => '1 workers · 1 threads · batch 1';

  /// Every `setoption` the controller sent, in order.
  final List<({String name, Object value})> options = [];

  @override
  Future<void> setOption(String name, Object value) async {
    options.add((name: name, value: value));
  }

  bool _alive = true;
  @override
  bool get isAlive => _alive;

  /// Pretends the process died, the way a crashed engine would.
  void die() => _alive = false;

  final _info = StreamController<BughouseInfo>.broadcast();
  @override
  Stream<BughouseInfo> get infoStream => _info.stream;

  /// Pushes a line onto [infoStream], as a running search would.
  void emit(BughouseInfo info) => _info.add(info);

  /// What the next [search] resolves with, keyed by the team it was configured
  /// for. Falls back to [defaultResult].
  final Map<Side, BughouseSearchResult> resultsByTeam = {};

  BughouseSearchResult defaultResult = const BughouseSearchResult(
    best: null,
    ponder: null,
    infos: [],
  );

  /// When set, the next [search] throws this instead of answering.
  Object? failNextSearch;

  /// Completes once a search is in flight, so a test can act mid-search.
  Completer<void>? searchStarted;

  @override
  Future<void> configure({
    required Side team,
    required bool hasTimeAdvantage,
    RequireMoveOn requireMoveOn = RequireMoveOn.none,
    int multiPv = 1,
  }) async {
    configurations.add((
      team: team,
      hasTimeAdvantage: hasTimeAdvantage,
      requireMoveOn: requireMoveOn,
      multiPv: multiPv,
    ));
  }

  @override
  Future<void> setPosition(
    BughouseState state, {
    List<String> moves = const [],
  }) async {
    positions.add(state.dualFen);
  }

  @override
  Future<BughouseSearchResult> search({
    Duration? movetime,
    int? nodes,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    searches.add((movetime: movetime, nodes: nodes));
    if (searchStarted != null && !searchStarted!.isCompleted) {
      searchStarted!.complete();
    }
    // Always a real timer, even at zero: a chain of instantly-completing
    // futures stays in the microtask queue, and the pump would then loop
    // forever without a single timer ever firing.
    await Future<void>.delayed(searchDelay);
    final failure = failNextSearch;
    if (failure != null) {
      failNextSearch = null;
      throw failure;
    }
    final team = configurations.isEmpty ? Side.white : configurations.last.team;
    return resultsByTeam[team] ?? defaultResult;
  }

  @override
  void stop() => stops++;

  @override
  Future<void> dispose() async {
    disposals++;
    _alive = false;
    await _info.close();
  }
}

/// A one-line result, which is what most of these tests need.
BughouseSearchResult scripted({
  required String best,
  int cp = -230,
  bool hadTimeAdvantage = false,
  List<int> alternatives = const [],
}) {
  final action = BughouseJointMove.tryParse(best);
  BughouseInfo line(int rank, int score) => BughouseInfo(
    depth: 4,
    scoreCp: score,
    nodes: 800,
    nps: 390,
    timeMs: 2000,
    multipv: rank,
    hadTimeAdvantage: hadTimeAdvantage,
    pv: action == null ? const [] : [action],
  );
  return BughouseSearchResult(
    best: action,
    ponder: null,
    infos: [
      line(1, cp),
      for (var i = 0; i < alternatives.length; i++)
        line(i + 2, alternatives[i]),
    ],
  );
}
