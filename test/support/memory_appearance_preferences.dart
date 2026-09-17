import 'dart:async';
import 'package:chess_auto_prep/features/settings/models/app_appearance.dart';
import 'package:chess_auto_prep/infrastructure/settings/persisted_appearance.dart';

class MemoryAppearancePreferences implements AppearancePreferences {
  AppAppearance value = AppAppearance.dark;
  bool readFails = false;
  bool writeFails = false;
  bool failAfterWrite = false;
  bool ignoreWrite = false;
  int reads = 0;
  final writes = <AppAppearance>[];
  Completer<void>? gate;
  @override
  Future<AppAppearance> read() async {
    reads++;
    if (readFails) throw StateError('read failed');
    return value;
  }

  @override
  Future<void> write(AppAppearance next) async {
    writes.add(next);
    await gate?.future;
    if (writeFails) throw StateError('write failed');
    if (!ignoreWrite) value = next;
    if (failAfterWrite) throw StateError('acknowledgement failed');
  }
}
