import '../models/loaded_repertoire.dart';

/// Derives chapter data without owning a file, widget or active session.
abstract interface class RepertoireDecoder {
  Future<LoadedRepertoire> build(
    String? pgnText, {
    required bool fallbackIsWhite,
  });
}
