import 'package:window_manager/window_manager.dart';
import '../../features/documents/repositories/desktop_close_port.dart';

class WindowCloseAdapter with WindowListener implements DesktopClosePort {
  void Function()? _requested;
  @override
  Future<void> attach(void Function() onCloseRequested) async {
    _requested = onCloseRequested;
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
  }

  @override
  void onWindowClose() => _requested?.call();
  @override
  Future<void> close() async {
    await windowManager.setPreventClose(false);
    try {
      await windowManager.close();
    } catch (_) {
      await windowManager.setPreventClose(true);
      rethrow;
    }
  }

  @override
  Future<void> detach() async {
    _requested = null;
    windowManager.removeListener(this);
    await windowManager.setPreventClose(false);
  }
}
