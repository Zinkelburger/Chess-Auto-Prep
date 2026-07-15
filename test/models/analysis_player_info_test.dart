import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/analysis_player_info.dart';

void main() {
  group('AnalysisPlayerInfo.playerKey', () {
    String keyFor(String platform, String username) =>
        AnalysisPlayerInfo(platform: platform, username: username).playerKey;

    test('passes platform usernames through unchanged (lowercased)', () {
      expect(keyFor('chesscom', 'Andrew_B-99'), 'chesscom_andrew_b-99');
      expect(keyFor('lichess', 'hikaru'), 'lichess_hikaru');
    });

    test('folds filename-hazardous characters to underscores', () {
      // '/' would nest the files in a subdirectory the player list never
      // scans, silently orphaning the import.
      expect(keyFor('import', 'AC/DC Fan'), 'import_ac_dc_fan');
      expect(keyFor('import', 'Carlsen, Magnus'), 'import_carlsen__magnus');
      expect(keyFor('import', 'a.b:c*d'), 'import_a_b_c_d');
    });

    test('names differing only in hazardous characters share a key', () {
      expect(keyFor('import', 'AC/DC'), keyFor('import', 'AC DC'));
    });
  });
}
