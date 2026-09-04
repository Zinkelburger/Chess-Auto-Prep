/// Where hole-hunt reports are stored: a JSON file whose path the caller
/// supplies (Player Analysis keys it per player and colour).
///
/// No resume state — v1 hunts are re-run from scratch, and a cancel saves a
/// partial report. The reading and writing is [HuntReportStore]; all this
/// file decides is which config type goes in it.
library;

import '../../audit/services/hunt_report_store.dart';
import 'hole_hunt_config.dart';

typedef HoleHuntSnapshot = HuntSnapshot<HoleHuntConfig>;

const HuntReportStore<HoleHuntConfig> holeHuntStore =
    HuntReportStore<HoleHuntConfig>(
      label: 'HoleHunt',
      encodeConfig: _encode,
      decodeConfig: _decode,
    );

Map<String, dynamic> _encode(HoleHuntConfig c) => c.toMap();

HoleHuntConfig _decode(Map<String, dynamic>? stored) =>
    stored == null ? const HoleHuntConfig() : HoleHuntConfig.fromMap(stored);
