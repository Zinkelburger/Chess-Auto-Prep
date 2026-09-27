import '../models/viewer_collection_load.dart';

/// Heavy decoding is scheduled by the adapter, independently of Flutter hosts.
abstract interface class PgnCollectionDecoder {
  Future<DecodedPgnCollection> decode(String content);
}
