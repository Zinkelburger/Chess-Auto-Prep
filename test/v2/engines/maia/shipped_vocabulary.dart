import 'dart:io';

import 'package:chess_auto_prep/v2/engines/maia/maia_vocabulary.dart';

/// The move table the app ships, so a test says what Maia is actually asked.
MaiaVocabulary shippedVocabulary() {
  final text = File('assets/data/all_moves_maia3.json').readAsStringSync();
  final vocabulary = MaiaVocabulary.parse(text);
  if (vocabulary == null) {
    throw StateError('assets/data/all_moves_maia3.json is not a move table');
  }
  return vocabulary;
}
