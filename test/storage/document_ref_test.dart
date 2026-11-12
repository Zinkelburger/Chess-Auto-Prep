import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a revision prints as the first eight characters of its hash', () {
    expect(Revision('0123456789${'a' * 54}').toString(), '01234567');
  });

  test('a revision is its bytes, whatever file supplied them', () {
    expect(
      const Revision('ab12', nativeIdentity: '1:2'),
      const Revision('ab12', nativeIdentity: '3:4'),
    );
  });
}
