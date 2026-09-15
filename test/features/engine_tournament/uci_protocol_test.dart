import 'package:chess_auto_prep/features/engine_tournament/services/uci_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UciOptionInfo.parse', () {
    test('a spin option carries its range and default', () {
      final option = UciOptionInfo.parse(
        'option name Hash type spin default 16 min 1 max 33554432',
      )!;
      expect(option.name, 'Hash');
      expect(option.type, 'spin');
      expect(option.defaultValue, '16');
      expect(option.min, '1');
      expect(option.max, '33554432');
      expect(option.values, isEmpty);
    });

    test('names with spaces survive because fields split on keywords', () {
      final option = UciOptionInfo.parse(
        'option name Skill Level type spin default 20 min 0 max 20',
      )!;
      expect(option.name, 'Skill Level');
    });

    test('every var starts a new choice, spaces and all', () {
      final option = UciOptionInfo.parse(
        'option name Style type combo default Solid var Solid var Very Active',
      )!;
      expect(option.type, 'combo');
      expect(option.defaultValue, 'Solid');
      expect(option.values, ['Solid', 'Very Active']);
    });

    test('a button has neither default nor range', () {
      final option = UciOptionInfo.parse('option name Clear Hash type button')!;
      expect(option.type, 'button');
      expect(option.defaultValue, isNull);
      expect(option.min, isNull);
    });

    test('a line without a name is not an option', () {
      expect(UciOptionInfo.parse('option type spin default 1'), isNull);
      expect(UciOptionInfo.parse('id name Foo'), isNull);
    });

    test('an option with no type defaults to string', () {
      expect(UciOptionInfo.parse('option name Foo')!.type, 'string');
    });
  });

  test('supportsOption is case-insensitive', () {
    const identity = UciIdentity(
      name: 'x',
      author: 'y',
      options: [UciOptionInfo(name: 'Threads', type: 'spin')],
    );
    expect(identity.supportsOption('threads'), isTrue);
    expect(identity.supportsOption('Hash'), isFalse);
  });
}
