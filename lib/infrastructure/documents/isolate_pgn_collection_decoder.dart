import 'dart:isolate';

import '../../chess_core/pgn/pgn_collection.dart';
import '../../features/documents/models/viewer_collection_load.dart';
import '../../features/documents/repositories/pgn_collection_decoder.dart';

class IsolatePgnCollectionDecoder implements PgnCollectionDecoder {
  const IsolatePgnCollectionDecoder();

  @override
  Future<DecodedPgnCollection> decode(String content) =>
      _decodeInWorker(content);
}

// A top-level closure avoids capturing a controller or other unsendable owner.
Future<DecodedPgnCollection> _decodeInWorker(String content) => Isolate.run(
  () => DecodedPgnCollection(
    parseMultiGamePgn(content),
    pgnCollectionPreamble(content),
  ),
);
