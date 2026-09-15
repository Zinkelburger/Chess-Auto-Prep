import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/opening_tsv.dart';

void main() {
  group('parseOpeningTsvRows', () {
    test('skips the header row, blank lines and short rows', () {
      final rows = parseOpeningTsvRows([
        'eco\tname\tpgn\n'
            'B20\tSicilian Defense\t1. e4 c5\n'
            '\n'
            'C20\tonly two columns\n'
            'A00\tPolish Opening\t1. b4\textra column\n',
      ]).toList();

      expect(rows, [
        (eco: 'B20', name: 'Sicilian Defense', movetext: '1. e4 c5'),
        (eco: 'A00', name: 'Polish Opening', movetext: '1. b4'),
      ]);
    });

    test('reads every volume in order and trims eco and name', () {
      final rows = parseOpeningTsvRows([
        'A00\t Anderssen Opening \t1. a3',
        'E60\tKing\'s Indian Defense\t1. d4 Nf6 2. c4 g6',
      ]).toList();

      expect(rows.map((r) => r.eco), ['A00', 'E60']);
      expect(rows.first.name, 'Anderssen Opening');
    });
  });

  test('openingTsvAssetPath names the bundled volume', () {
    expect(openingTsvVolumes, ['a', 'b', 'c', 'd', 'e']);
    expect(openingTsvAssetPath('c'), 'assets/data/openings/c.tsv');
  });
}
