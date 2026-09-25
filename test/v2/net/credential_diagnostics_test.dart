import 'package:chess_auto_prep/v2/chess/explorer_choice.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:chess_auto_prep/v2/net/lichess_explorer.dart';
import 'package:chess_auto_prep/v2/net/lichess_studies.dart';
import 'package:chess_auto_prep/v2/net/recent_games.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

void main() {
  const secret = 'private-diagnostic-token';
  for (final client in ['studies', 'explorer', 'games']) {
    test('$client transport errors do not log credentials', () async {
      final lines = <String>[];
      void sink(LogEntry entry) => lines.add(entry.line);
      log.install(sink);
      addTearDown(() => log.remove(sink));
      final http = MockClient((request) async {
        throw StateError(request.headers['Authorization']!);
      });
      Future<String?> token() async => secret;
      switch (client) {
        case 'studies':
          await LichessStudyApi(
            http,
            token: token,
          ).fetch(const LichessStudyLink(studyId: 'abcdefgh'));
        case 'explorer':
          await LichessExplorerApi(
            http,
            token: token,
            wait: (_) async {},
          ).fetch(const ExplorerQuery(Fen.initial, ExplorerChoice.defaults));
        case 'games':
          await LichessGamesApi(
            http,
            token: token,
            wait: (_) async {},
          ).recent('fixture', max: 1);
      }
      expect(lines, isNotEmpty);
      expect(lines.join(), isNot(contains(secret)));
    });
  }
}
