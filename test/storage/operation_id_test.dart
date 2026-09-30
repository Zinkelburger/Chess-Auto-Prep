import 'package:chess_auto_prep/storage/operation_id.dart';
import 'package:chess_auto_prep/storage/recovery_files.dart';
import 'package:chess_auto_prep/storage/relocation_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a minted id is an operation id and names a deleted chapter', () {
    final minted = {for (var i = 0; i < 1000; i++) newOperationId()};
    expect(minted, hasLength(1000));
    for (final id in minted) {
      expect(OperationId(id), id);
      expect(() => validateDeletionId(id), returnsNormally);
    }
  });

  test('ids sort by the time they were minted', () {
    final first = newOperationId();
    final second = newOperationId();
    expect(
      int.parse(first.split('-').first),
      lessThanOrEqualTo(int.parse(second.split('-').first)),
    );
  });

  test('the grammar holds at its edges', () {
    for (final id in ['a', '0', 'A_b-9', 'x' * 128]) {
      expect(OperationId(id), id);
    }
    for (final id in [
      '',
      '../x',
      'x' * 129,
      'a\u0000',
      '-leading',
      '_leading',
      'a.json',
      'a/b',
      'a b',
    ]) {
      expect(
        () => OperationId(id),
        throwsA(isA<RecoveryRequired>()),
        reason: id,
      );
    }
  });
}
