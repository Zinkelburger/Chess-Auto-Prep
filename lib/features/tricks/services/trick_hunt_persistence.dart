/// Where trick-hunt reports are stored: a JSON file whose path the caller
/// supplies (Player Analysis keys it per player and colour).
///
/// No resume state — v1 hunts are re-run from scratch, and a cancel saves a
/// partial report. The reading and writing is [HuntReportStore]; all this
/// file decides is which config type goes in it.
library;

import '../../audit/services/hunt_report_store.dart';
import 'trick_hunt_config.dart';

typedef TrickHuntSnapshot = HuntSnapshot<TrickHuntConfig>;

const HuntReportStore<TrickHuntConfig> trickHuntStore =
    HuntReportStore<TrickHuntConfig>(
      label: 'TrickHunt',
      encodeConfig: _encode,
      decodeConfig: _decode,
    );

Map<String, dynamic> _encode(TrickHuntConfig c) => c.toMap();

TrickHuntConfig _decode(Map<String, dynamic>? stored) =>
    stored == null ? const TrickHuntConfig() : TrickHuntConfig.fromMap(stored);
